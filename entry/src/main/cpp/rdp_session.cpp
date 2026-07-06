#include "rdp_session.h"

#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstring>

#include <freerdp/gdi/gdi.h>
#include <freerdp/settings.h>
#include <freerdp/error.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <native_buffer/native_buffer.h>

#include "hm_log.h"

namespace hmrdp {

namespace {

// freerdp 上下文扩展：携带宿主会话指针
struct HmContext {
    rdpContext context;
    RdpSession* session;
};

RdpSession* SessionOf(rdpContext* context)
{
    return reinterpret_cast<HmContext*>(context)->session;
}

BOOL HmBeginPaint(rdpContext* context)
{
    HGDI_WND hwnd = context->gdi->primary->hdc->hwnd;
    hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;
    return TRUE;
}

BOOL HmEndPaint(rdpContext* context)
{
    HGDI_WND hwnd = context->gdi->primary->hdc->hwnd;
    if (hwnd->invalid->null)
        return TRUE;
    SessionOf(context)->OnGraphicsDirty();
    return TRUE;
}

BOOL HmDesktopResize(rdpContext* context)
{
    rdpSettings* settings = context->settings;
    const UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    const UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, w, h))
        return FALSE;
    SessionOf(context)->OnDesktopResize(w, h);
    return TRUE;
}

BOOL HmPreConnect(freerdp* instance)
{
    // 通道装载（cliprdr 等后续里程碑启用时自动生效）
    if (!freerdp_client_load_addins(instance->context->channels, instance->context->settings))
        return FALSE;
    return TRUE;
}

BOOL HmPostConnect(freerdp* instance)
{
    if (!gdi_init(instance, PIXEL_FORMAT_RGBX32))
        return FALSE;

    rdpUpdate* update = instance->context->update;
    update->BeginPaint = HmBeginPaint;
    update->EndPaint = HmEndPaint;
    update->DesktopResize = HmDesktopResize;

    RdpSession* session = SessionOf(instance->context);
    session->OnDesktopResize(instance->context->gdi->width, instance->context->gdi->height);
    session->NotifyState(SessionState::Connected, "");
    return TRUE;
}

void HmPostDisconnect(freerdp* instance)
{
    gdi_free(instance);
}

// TODO(M3b): 接 ArkTS 证书信任弹窗；当前仅本会话临时接受
DWORD HmVerifyCertificateEx(freerdp* /*instance*/, const char* host, UINT16 port,
                            const char* /*common_name*/, const char* /*subject*/,
                            const char* /*issuer*/, const char* fingerprint, DWORD /*flags*/)
{
    HMLOGW("接受证书(临时): %{public}s:%{public}u fp=%{private}s", host, port, fingerprint);
    return 2; // 仅本会话接受
}

BOOL HmClientNew(freerdp* instance, rdpContext* context)
{
    instance->PreConnect = HmPreConnect;
    instance->PostConnect = HmPostConnect;
    instance->PostDisconnect = HmPostDisconnect;
    instance->VerifyCertificateEx = HmVerifyCertificateEx;
    (void)context;
    return TRUE;
}

void HmClientFree(freerdp* /*instance*/, rdpContext* /*context*/) {}

// 把 winpr 日志汇入 hilog，便于真机排障
BOOL WlogToHilog(const wLogMessage* msg)
{
    if (!msg || !msg->TextString)
        return TRUE;
    LogLevel level = msg->Level >= WLOG_ERROR ? LOG_ERROR
                     : msg->Level >= WLOG_WARN ? LOG_WARN
                                               : LOG_INFO;
    OH_LOG_Print(LOG_APP, level, HM_DOMAIN, "FreeRDP", "%{public}s", msg->TextString);
    return TRUE;
}

void SetupWlog()
{
    wLog* root = WLog_GetRoot();
    WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK);
    wLogAppender* appender = WLog_GetLogAppender(root);
    if (!appender)
        return;
    static wLogCallbacks callbacks = {};
    callbacks.message = WlogToHilog;
    WLog_ConfigureAppender(appender, "callbacks", reinterpret_cast<void*>(&callbacks));
    WLog_SetLogLevel(root, WLOG_INFO);
}

} // namespace

RdpSession::RdpSession(SessionConfig config, StateCallback cb, void* cbUserData)
    : config_(std::move(config)), stateCb_(cb), stateCbUserData_(cbUserData)
{
}

RdpSession::~RdpSession()
{
    RequestStop();
    Join();
    if (context_) {
        freerdp_client_context_free(context_);
        context_ = nullptr;
    }
    if (stopEvent_) {
        CloseHandle(stopEvent_);
        stopEvent_ = nullptr;
    }
}

bool RdpSession::ApplySettings()
{
    rdpSettings* settings = context_->settings;
    bool ok = true;
    ok = ok && freerdp_settings_set_string(settings, FreeRDP_ServerHostname, config_.host.c_str());
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, config_.port);
    ok = ok && freerdp_settings_set_string(settings, FreeRDP_Username, config_.username.c_str());
    ok = ok && freerdp_settings_set_string(settings, FreeRDP_Password, config_.password.c_str());
    if (!config_.domain.empty())
        ok = ok && freerdp_settings_set_string(settings, FreeRDP_Domain, config_.domain.c_str());

    uint32_t w = config_.width;
    uint32_t h = config_.height;
    if (w == 0 || h == 0) {
        std::lock_guard<std::mutex> lock(windowMutex_);
        w = static_cast<uint32_t>(surfaceWidth_);
        h = static_cast<uint32_t>(surfaceHeight_);
    }
    if (w == 0 || h == 0) {
        w = 1280;
        h = 720;
    }
    w &= ~1u; // 偶数对齐（H.264/编解码器友好）
    h &= ~1u;
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, w);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, h);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);

    // HiDPI：让 Windows 按比例放大 UI
    uint32_t scale = config_.scale;
    if (scale < 100)
        scale = 100;
    if (scale > 500)
        scale = 500;
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, scale);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, 100);

    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
    // M4a 启用 GFX + H.264 前先走经典位图更新路径
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_FastPathOutput, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_FastPathInput, TRUE);

    return ok;
}

bool RdpSession::Start()
{
    SetupWlog();

    RDP_CLIENT_ENTRY_POINTS ep = {};
    ep.Version = RDP_CLIENT_INTERFACE_VERSION;
    ep.Size = sizeof(ep);
    ep.ContextSize = sizeof(HmContext);
    ep.ClientNew = HmClientNew;
    ep.ClientFree = HmClientFree;

    context_ = freerdp_client_context_new(&ep);
    if (!context_) {
        HMLOGE("freerdp_client_context_new 失败");
        return false;
    }
    reinterpret_cast<HmContext*>(context_)->session = this;
    instance_ = context_->instance;

    if (!ApplySettings()) {
        HMLOGE("应用连接设置失败");
        freerdp_client_context_free(context_);
        context_ = nullptr;
        return false;
    }

    stopEvent_ = CreateEventA(nullptr, TRUE, FALSE, nullptr);
    if (!stopEvent_)
        return false;

    running_.store(true);
    thread_ = std::thread([this]() { ThreadMain(); });
    return true;
}

void RdpSession::RequestStop()
{
    if (stopEvent_)
        SetEvent(stopEvent_);
}

void RdpSession::Join()
{
    if (thread_.joinable())
        thread_.join();
}

void RdpSession::ThreadMain()
{
    NotifyState(SessionState::Connecting, "");

    if (!freerdp_connect(instance_)) {
        const UINT32 err = freerdp_get_last_error(context_);
        const char* text = freerdp_get_last_error_string(err);
        HMLOGE("连接失败: 0x%{public}x %{public}s", err, text ? text : "");
        NotifyState(SessionState::Disconnected, text ? text : "connect failed");
        running_.store(false);
        return;
    }

    while (!freerdp_shall_disconnect_context(context_)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {};
        DWORD count = freerdp_get_event_handles(context_, handles, MAXIMUM_WAIT_OBJECTS - 1);
        if (count == 0) {
            HMLOGE("freerdp_get_event_handles 失败");
            break;
        }
        handles[count++] = stopEvent_;

        const DWORD status = WaitForMultipleObjects(count, handles, FALSE, INFINITE);
        if (status == WAIT_FAILED)
            break;
        if (WaitForSingleObject(stopEvent_, 0) == WAIT_OBJECT_0)
            break;
        if (!freerdp_check_event_handles(context_)) {
            if (freerdp_get_last_error(context_) == FREERDP_ERROR_SUCCESS)
                HMLOGW("会话事件处理失败，断开");
            break;
        }
    }

    const UINT32 err = freerdp_get_last_error(context_);
    freerdp_disconnect(instance_);
    running_.store(false);

    const char* text = (err != FREERDP_ERROR_SUCCESS) ? freerdp_get_last_error_string(err) : "";
    NotifyState(SessionState::Disconnected, text ? text : "");
}

void RdpSession::NotifyState(SessionState state, const char* message)
{
    if (stateCb_)
        stateCb_(state, message ? message : "", stateCbUserData_);
}

void RdpSession::AttachWindow(OHNativeWindow* window, uint64_t width, uint64_t height)
{
    std::lock_guard<std::mutex> lock(windowMutex_);
    window_ = window;
    surfaceWidth_ = width;
    surfaceHeight_ = height;
    geometryDirty_ = true;
}

void RdpSession::DetachWindow()
{
    std::lock_guard<std::mutex> lock(windowMutex_);
    window_ = nullptr;
}

void RdpSession::OnDesktopResize(uint32_t /*w*/, uint32_t /*h*/)
{
    std::lock_guard<std::mutex> lock(windowMutex_);
    geometryDirty_ = true;
}

void RdpSession::OnGraphicsDirty()
{
    PresentFrame();
}

bool RdpSession::PresentFrame()
{
    rdpGdi* gdi = context_->gdi;
    if (!gdi || !gdi->primary_buffer)
        return false;

    std::lock_guard<std::mutex> lock(windowMutex_);
    if (!window_)
        return true; // surface 未就绪时静默丢帧

    const int32_t width = gdi->width;
    const int32_t height = gdi->height;

    if (geometryDirty_) {
        // buffer 尺寸 = 远端桌面尺寸，合成器负责缩放到 surface
        OH_NativeWindow_NativeWindowHandleOpt(window_, SET_BUFFER_GEOMETRY, width, height);
        OH_NativeWindow_NativeWindowHandleOpt(window_, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBX_8888);
        geometryDirty_ = false;
    }

    OHNativeWindowBuffer* buffer = nullptr;
    int fenceFd = -1;
    if (OH_NativeWindow_NativeWindowRequestBuffer(window_, &buffer, &fenceFd) != 0 || !buffer) {
        HMLOGW("RequestBuffer 失败");
        return false;
    }
    if (fenceFd >= 0) {
        struct pollfd pfd = { fenceFd, POLLIN, 0 };
        poll(&pfd, 1, 100);
        close(fenceFd);
        fenceFd = -1;
    }

    BufferHandle* handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
    if (!handle) {
        OH_NativeWindow_NativeWindowAbortBuffer(window_, buffer);
        return false;
    }

    void* mapped = mmap(nullptr, handle->size, PROT_READ | PROT_WRITE, MAP_SHARED, handle->fd, 0);
    if (mapped == MAP_FAILED) {
        OH_NativeWindow_NativeWindowAbortBuffer(window_, buffer);
        return false;
    }

    // NativeWindow 多缓冲轮转，无法保证残留内容，整帧拷贝保证正确性（M4b 做脏区优化）
    const uint8_t* src = gdi->primary_buffer;
    uint8_t* dst = static_cast<uint8_t*>(mapped);
    const uint32_t srcStride = gdi->stride;
    const uint32_t dstStride = static_cast<uint32_t>(handle->stride);
    const uint32_t copyW = static_cast<uint32_t>(width) * 4u;
    const int32_t copyH = std::min<int32_t>(height, handle->height);
    if (srcStride == dstStride && static_cast<int32_t>(handle->height) >= height) {
        memcpy(dst, src, static_cast<size_t>(srcStride) * height);
    } else {
        for (int32_t y = 0; y < copyH; y++)
            memcpy(dst + static_cast<size_t>(y) * dstStride, src + static_cast<size_t>(y) * srcStride,
                   std::min(copyW, dstStride));
    }

    munmap(mapped, handle->size);

    Region region = {};
    region.rects = nullptr;    // 全帧
    region.rectNumber = 0;
    if (OH_NativeWindow_NativeWindowFlushBuffer(window_, buffer, -1, region) != 0) {
        HMLOGW("FlushBuffer 失败");
        return false;
    }
    return true;
}

} // namespace hmrdp
