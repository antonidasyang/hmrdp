/* 链接完整性验证：触及 libfreerdp/libwinpr/client-common 的关键符号。
 * 只验证交叉编译产物可链接，不在宿主机运行。 */
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/h264.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>

static BOOL test_client_new(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
	return TRUE;
}
static void test_client_free(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
}
static int test_client_start(rdpContext* context)
{
	(void)context;
	return 0;
}
static int test_client_stop(rdpContext* context)
{
	(void)context;
	return 0;
}

int main(void)
{
	RDP_CLIENT_ENTRY_POINTS ep = { 0 };
	ep.Version = RDP_CLIENT_INTERFACE_VERSION;
	ep.Size = sizeof(ep);
	ep.ContextSize = sizeof(rdpContext);
	ep.ClientNew = test_client_new;
	ep.ClientFree = test_client_free;
	ep.ClientStart = test_client_start;
	ep.ClientStop = test_client_stop;

	winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT);
	rdpContext* ctx = freerdp_client_context_new(&ep);
	if (!ctx)
		return 1;
	freerdp* instance = ctx->instance;
	freerdp_settings_set_string(instance->context->settings, FreeRDP_ServerHostname, "example");
	freerdp_settings_set_bool(instance->context->settings, FreeRDP_SupportGraphicsPipeline, TRUE);
	gdi_init(instance, PIXEL_FORMAT_BGRA32);
	H264_CONTEXT* h264 = h264_context_new(FALSE);
	if (h264)
		h264_context_free(h264);
	gdi_free(instance);
	freerdp_client_context_free(ctx);
	return 0;
}
