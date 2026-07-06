/**
 * FreeRDP: H.264 subsystem backed by OpenHarmony AVCodec (hardware decode).
 *
 * Provides AVC420 decode for the RDP Graphics Pipeline by wrapping
 * OH_VideoDecoder. Output is copied into tightly-packed I420 planes that
 * FreeRDP's YUV->RGB stage consumes.
 *
 * This file is part of the HMRDP project and is licensed under the
 * Apache License, Version 2.0, matching FreeRDP.
 */

#include <winpr/wlog.h>
#include <winpr/synch.h>

/* internal header: full S_H264_CONTEXT definition + subsystem struct */
#include "h264.h"

#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_averrors.h>

#define TAG FREERDP_TAG("codec.h264.ohos")

#define OHOS_FIFO_CAP 32

typedef struct
{
	uint32_t index;
	OH_AVBuffer* buffer;
} OhosBufferSlot;

typedef struct
{
	OH_AVCodec* decoder;

	pthread_mutex_t lock;
	pthread_cond_t cond;

	OhosBufferSlot inFifo[OHOS_FIFO_CAP];
	int inHead, inTail, inCount;

	OhosBufferSlot outFifo[OHOS_FIFO_CAP];
	int outHead, outTail, outCount;

	BOOL started;
	BOOL error;
	UINT32 cfgWidth;
	UINT32 cfgHeight;
	INT64 pts;

	/* tightly-packed I420 output owned by this subsystem */
	BYTE* plane[3];
	UINT32 planeCap[3];
} H264_CONTEXT_OHOS;

static void ohos_fifo_push(OhosBufferSlot* fifo, int* head, int* tail, int* count, uint32_t index,
                           OH_AVBuffer* buffer)
{
	if (*count >= OHOS_FIFO_CAP)
		return; /* drop; should not happen with proper buffer counts */
	fifo[*tail].index = index;
	fifo[*tail].buffer = buffer;
	*tail = (*tail + 1) % OHOS_FIFO_CAP;
	(*count)++;
}

static BOOL ohos_fifo_pop(OhosBufferSlot* fifo, int* head, int* tail, int* count, OhosBufferSlot* out)
{
	if (*count <= 0)
		return FALSE;
	*out = fifo[*head];
	*head = (*head + 1) % OHOS_FIFO_CAP;
	(*count)--;
	return TRUE;
}

static void on_error(OH_AVCodec* codec, int32_t errorCode, void* userData)
{
	H264_CONTEXT_OHOS* sys = (H264_CONTEXT_OHOS*)userData;
	(void)codec;
	pthread_mutex_lock(&sys->lock);
	sys->error = TRUE;
	pthread_cond_broadcast(&sys->cond);
	pthread_mutex_unlock(&sys->lock);
}

static void on_stream_changed(OH_AVCodec* codec, OH_AVFormat* format, void* userData)
{
	(void)codec;
	(void)format;
	(void)userData;
}

static void on_need_input(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData)
{
	H264_CONTEXT_OHOS* sys = (H264_CONTEXT_OHOS*)userData;
	(void)codec;
	pthread_mutex_lock(&sys->lock);
	ohos_fifo_push(sys->inFifo, &sys->inHead, &sys->inTail, &sys->inCount, index, buffer);
	pthread_cond_broadcast(&sys->cond);
	pthread_mutex_unlock(&sys->lock);
}

static void on_new_output(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData)
{
	H264_CONTEXT_OHOS* sys = (H264_CONTEXT_OHOS*)userData;
	(void)codec;
	pthread_mutex_lock(&sys->lock);
	ohos_fifo_push(sys->outFifo, &sys->outHead, &sys->outTail, &sys->outCount, index, buffer);
	pthread_cond_broadcast(&sys->cond);
	pthread_mutex_unlock(&sys->lock);
}

static void ohos_teardown_decoder(H264_CONTEXT_OHOS* sys)
{
	if (!sys->decoder)
		return;
	if (sys->started)
	{
		OH_VideoDecoder_Stop(sys->decoder);
		sys->started = FALSE;
	}
	OH_VideoDecoder_Destroy(sys->decoder);
	sys->decoder = NULL;
	pthread_mutex_lock(&sys->lock);
	sys->inHead = sys->inTail = sys->inCount = 0;
	sys->outHead = sys->outTail = sys->outCount = 0;
	sys->error = FALSE;
	pthread_mutex_unlock(&sys->lock);
}

static BOOL ohos_configure(H264_CONTEXT* h264, H264_CONTEXT_OHOS* sys, UINT32 width, UINT32 height)
{
	ohos_teardown_decoder(sys);

	sys->decoder = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
	if (!sys->decoder)
	{
		WLog_Print(h264->log, WLOG_ERROR, "OH_VideoDecoder_CreateByMime failed");
		return FALSE;
	}

	OH_AVCodecCallback cb;
	cb.onError = on_error;
	cb.onStreamChanged = on_stream_changed;
	cb.onNeedInputBuffer = on_need_input;
	cb.onNewOutputBuffer = on_new_output;
	if (OH_VideoDecoder_RegisterCallback(sys->decoder, cb, sys) != AV_ERR_OK)
	{
		WLog_Print(h264->log, WLOG_ERROR, "OH_VideoDecoder_RegisterCallback failed");
		return FALSE;
	}

	OH_AVFormat* format = OH_AVFormat_Create();
	if (!format)
		return FALSE;
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, (int32_t)width);
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, (int32_t)height);
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_YUVI420);
	OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, 60.0);
	/* low latency: emit one frame per input, no reordering delay (RDP has no B-frames) */
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);

	OH_AVErrCode rc = OH_VideoDecoder_Configure(sys->decoder, format);
	OH_AVFormat_Destroy(format);
	if (rc != AV_ERR_OK)
	{
		WLog_Print(h264->log, WLOG_ERROR, "OH_VideoDecoder_Configure failed: %d", rc);
		return FALSE;
	}
	if (OH_VideoDecoder_Prepare(sys->decoder) != AV_ERR_OK)
	{
		WLog_Print(h264->log, WLOG_ERROR, "OH_VideoDecoder_Prepare failed");
		return FALSE;
	}
	if (OH_VideoDecoder_Start(sys->decoder) != AV_ERR_OK)
	{
		WLog_Print(h264->log, WLOG_ERROR, "OH_VideoDecoder_Start failed");
		return FALSE;
	}
	sys->started = TRUE;
	sys->cfgWidth = width;
	sys->cfgHeight = height;
	sys->pts = 0;
	return TRUE;
}

/* wait up to timeoutMs for a predicate on the input/output fifo */
static BOOL ohos_wait_input(H264_CONTEXT_OHOS* sys, OhosBufferSlot* slot, int timeoutMs)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += timeoutMs / 1000;
	ts.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
	if (ts.tv_nsec >= 1000000000L)
	{
		ts.tv_sec++;
		ts.tv_nsec -= 1000000000L;
	}
	pthread_mutex_lock(&sys->lock);
	while (sys->inCount == 0 && !sys->error)
	{
		if (pthread_cond_timedwait(&sys->cond, &sys->lock, &ts) != 0)
			break;
	}
	BOOL ok = !sys->error &&
	          ohos_fifo_pop(sys->inFifo, &sys->inHead, &sys->inTail, &sys->inCount, slot);
	pthread_mutex_unlock(&sys->lock);
	return ok;
}

static BOOL ohos_wait_output(H264_CONTEXT_OHOS* sys, OhosBufferSlot* slot, int timeoutMs)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += timeoutMs / 1000;
	ts.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
	if (ts.tv_nsec >= 1000000000L)
	{
		ts.tv_sec++;
		ts.tv_nsec -= 1000000000L;
	}
	pthread_mutex_lock(&sys->lock);
	while (sys->outCount == 0 && !sys->error)
	{
		if (pthread_cond_timedwait(&sys->cond, &sys->lock, &ts) != 0)
			break;
	}
	BOOL ok = !sys->error &&
	          ohos_fifo_pop(sys->outFifo, &sys->outHead, &sys->outTail, &sys->outCount, slot);
	pthread_mutex_unlock(&sys->lock);
	return ok;
}

static BOOL ohos_ensure_plane(H264_CONTEXT_OHOS* sys, int i, UINT32 size)
{
	if (sys->planeCap[i] >= size && sys->plane[i])
		return TRUE;
	BYTE* p = (BYTE*)realloc(sys->plane[i], size);
	if (!p)
		return FALSE;
	sys->plane[i] = p;
	sys->planeCap[i] = size;
	return TRUE;
}

static int ohos_decompress(H264_CONTEXT* h264, const BYTE* pSrcData, UINT32 SrcSize)
{
	H264_CONTEXT_OHOS* sys = (H264_CONTEXT_OHOS*)h264->pSystemData;
	if (!sys || !pSrcData || SrcSize == 0)
		return -1;

	const UINT32 width = h264->width;
	const UINT32 height = h264->height;
	if (width == 0 || height == 0)
		return -1;

	if (!sys->decoder || sys->cfgWidth != width || sys->cfgHeight != height)
	{
		if (!ohos_configure(h264, sys, width, height))
			return -1;
	}

	/* --- feed one access unit --- */
	OhosBufferSlot in;
	if (!ohos_wait_input(sys, &in, 1000))
	{
		WLog_Print(h264->log, WLOG_ERROR, "no input buffer available");
		return -1;
	}
	uint8_t* dst = OH_AVBuffer_GetAddr(in.buffer);
	int32_t cap = OH_AVBuffer_GetCapacity(in.buffer);
	if (!dst || cap < (int32_t)SrcSize)
	{
		WLog_Print(h264->log, WLOG_ERROR, "input buffer too small: %d < %u", cap, SrcSize);
		return -1;
	}
	memcpy(dst, pSrcData, SrcSize);
	OH_AVCodecBufferAttr attr;
	memset(&attr, 0, sizeof(attr));
	attr.pts = sys->pts;
	attr.size = (int32_t)SrcSize;
	attr.offset = 0;
	attr.flags = 0; /* AVCODEC_BUFFER_FLAGS_NONE */
	sys->pts += 16667; /* ~60fps in microseconds; monotonic only */
	OH_AVBuffer_SetBufferAttr(in.buffer, &attr);
	if (OH_VideoDecoder_PushInputBuffer(sys->decoder, in.index) != AV_ERR_OK)
	{
		WLog_Print(h264->log, WLOG_ERROR, "OH_VideoDecoder_PushInputBuffer failed");
		return -1;
	}

	/* --- collect the decoded frame (low-latency => 1-in-1-out) --- */
	OhosBufferSlot out;
	if (!ohos_wait_output(sys, &out, 1000))
	{
		WLog_Print(h264->log, WLOG_WARN, "no output frame within timeout");
		return -1;
	}

	uint8_t* yuv = OH_AVBuffer_GetAddr(out.buffer);
	if (!yuv)
	{
		OH_VideoDecoder_FreeOutputBuffer(sys->decoder, out.index);
		return -1;
	}

	/* obtain the hardware buffer layout (row stride / slice height may exceed w/h) */
	UINT32 srcStrideY = width;
	UINT32 sliceH = height;
	OH_AVFormat* odesc = OH_VideoDecoder_GetOutputDescription(sys->decoder);
	if (odesc)
	{
		int32_t v = 0;
		if (OH_AVFormat_GetIntValue(odesc, OH_MD_KEY_VIDEO_STRIDE, &v) && v > 0)
			srcStrideY = (UINT32)v;
		if (OH_AVFormat_GetIntValue(odesc, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &v) && v > 0)
			sliceH = (UINT32)v;
		OH_AVFormat_Destroy(odesc);
	}
	const UINT32 srcStrideC = srcStrideY / 2;
	const UINT32 halfW = (width + 1) / 2;
	const UINT32 halfH = (height + 1) / 2;

	const uint8_t* srcY = yuv;
	const uint8_t* srcU = srcY + (size_t)srcStrideY * sliceH;
	const uint8_t* srcV = srcU + (size_t)srcStrideC * ((sliceH + 1) / 2);

	if (!ohos_ensure_plane(sys, 0, width * height) ||
	    !ohos_ensure_plane(sys, 1, halfW * halfH) || !ohos_ensure_plane(sys, 2, halfW * halfH))
	{
		OH_VideoDecoder_FreeOutputBuffer(sys->decoder, out.index);
		return -1;
	}

	for (UINT32 y = 0; y < height; y++)
		memcpy(sys->plane[0] + (size_t)y * width, srcY + (size_t)y * srcStrideY, width);
	for (UINT32 y = 0; y < halfH; y++)
		memcpy(sys->plane[1] + (size_t)y * halfW, srcU + (size_t)y * srcStrideC, halfW);
	for (UINT32 y = 0; y < halfH; y++)
		memcpy(sys->plane[2] + (size_t)y * halfW, srcV + (size_t)y * srcStrideC, halfW);

	OH_VideoDecoder_FreeOutputBuffer(sys->decoder, out.index);

	h264->iStride[0] = width;
	h264->iStride[1] = halfW;
	h264->iStride[2] = halfW;
	h264->pYUVData[0] = sys->plane[0];
	h264->pYUVData[1] = sys->plane[1];
	h264->pYUVData[2] = sys->plane[2];
	return 1;
}

static int ohos_compress(H264_CONTEXT* h264, const BYTE** pSrcYuv, const UINT32* pStride,
                         BYTE** ppDstData, UINT32* pDstSize)
{
	(void)h264;
	(void)pSrcYuv;
	(void)pStride;
	(void)ppDstData;
	(void)pDstSize;
	return -1; /* encode not supported */
}

static void ohos_uninit(H264_CONTEXT* h264)
{
	H264_CONTEXT_OHOS* sys = (H264_CONTEXT_OHOS*)h264->pSystemData;
	if (!sys)
		return;
	ohos_teardown_decoder(sys);
	for (int i = 0; i < 3; i++)
		free(sys->plane[i]);
	pthread_cond_destroy(&sys->cond);
	pthread_mutex_destroy(&sys->lock);
	free(sys);
	h264->pSystemData = NULL;
}

static BOOL ohos_init(H264_CONTEXT* h264)
{
	if (h264->Compressor)
		return FALSE; /* decode only */

	H264_CONTEXT_OHOS* sys = (H264_CONTEXT_OHOS*)calloc(1, sizeof(H264_CONTEXT_OHOS));
	if (!sys)
		return FALSE;
	pthread_mutex_init(&sys->lock, NULL);
	pthread_cond_init(&sys->cond, NULL);
	h264->pSystemData = (void*)sys;
	return TRUE;
}

const H264_CONTEXT_SUBSYSTEM g_Subsystem_ohos = { "OHOS-AVCodec", ohos_init, ohos_uninit,
	                                               ohos_decompress, ohos_compress };
