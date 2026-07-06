#include "rdp_session.h"

#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstring>

#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/error.h>
#include <freerdp/client/channels.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <native_buffer/native_buffer.h>

#include <algorithm>

#include "hm_log.h"

namespace hmrdp {

namespace {

// freerdp 上下文扩展：内嵌 rdpClientContext 以复用 FreeRDP 客户端通道 helper
struct HmContext {
    rdpClientContext client;
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
    rdpContext* context = instance->context;
    // 订阅通道连接事件：GFX 通道就绪时 FreeRDP helper 自动挂接 gdi 图形管线
    PubSub_SubscribeChannelConnected(context->pubSub,
                                     freerdp_client_OnChannelConnectedEventHandler);
    PubSub_SubscribeChannelDisconnected(context->pubSub,
                                        freerdp_client_OnChannelDisconnectedEventHandler);

    if (!freerdp_client_load_addins(context->channels, context->settings))
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

DWORD HmVerifyCertificateEx(freerdp* instance, const char* host, UINT16 port,
                            const char* common_name, const char* subject, const char* issuer,
                            const char* fingerprint, DWORD /*flags*/)
{
    CertInfo info = { host, port, common_name, subject, issuer, fingerprint, false };
    return SessionOf(instance->context)->RequestCertDecision(info);
}

DWORD HmVerifyChangedCertificateEx(freerdp* instance, const char* host, UINT16 port,
                                   const char* common_name, const char* subject,
                                   const char* issuer, const char* new_fingerprint,
                                   const char* /*old_subject*/, const char* /*old_issuer*/,
                                   const char* /*old_fingerprint*/, DWORD /*flags*/)
{
    CertInfo info = { host, port, common_name, subject, issuer, new_fingerprint, true };
    return SessionOf(instance->context)->RequestCertDecision(info);
}

BOOL HmClientNew(freerdp* instance, rdpContext* context)
{
    instance->PreConnect = HmPreConnect;
    instance->PostConnect = HmPostConnect;
    instance->PostDisconnect = HmPostDisconnect;
    instance->VerifyCertificateEx = HmVerifyCertificateEx;
    instance->VerifyChangedCertificateEx = HmVerifyChangedCertificateEx;
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
    if (inputSignal_) {
        CloseHandle(inputSignal_);
        inputSignal_ = nullptr;
    }
    if (certEvent_) {
        CloseHandle(certEvent_);
        certEvent_ = nullptr;
    }
}

void RdpSession::SetCertCallback(CertCallback cb, void* userData)
{
    certCb_ = cb;
    certCbUserData_ = userData;
}

uint32_t RdpSession::RequestCertDecision(const CertInfo& info)
{
    if (!certCb_ || !certEvent_) {
        HMLOGW("无证书确认回调，默认本次接受: %{public}s:%{public}u", info.host, info.port);
        return 2;
    }
    certDecision_.store(-1);
    certCb_(info, certCbUserData_);

    // 等待用户决策；stopEvent 触发或超时(120s)按拒绝处理
    HANDLE handles[2] = { certEvent_, stopEvent_ };
    const DWORD status = WaitForMultipleObjects(2, handles, FALSE, 120000);
    if (status != WAIT_OBJECT_0)
        return 0;
    const int32_t decision = certDecision_.load();
    return decision < 0 ? 0 : static_cast<uint32_t>(decision);
}

void RdpSession::ProvideCertDecision(int32_t decision)
{
    certDecision_.store(decision);
    if (certEvent_)
        SetEvent(certEvent_);
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

    // RDP8+ 图形管线 + H.264（AVC420 硬解，见 h264_ohos 子系统）
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, FALSE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, FALSE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE); // 无 H.264 时的软件回退
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GfxSmallCache, FALSE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GfxThinClient, FALSE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_SupportDynamicChannels, TRUE);

    // 经典编解码回退（GFX 未协商时）
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_FastPathOutput, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_FastPathInput, TRUE);

    // 网络级自动重连（RDP auto-reconnect cookie）
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, TRUE);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_AutoReconnectMaxRetries, 3);

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
    inputSignal_ = CreateEventA(nullptr, FALSE, FALSE, nullptr); // 自动复位
    certEvent_ = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    if (!stopEvent_ || !inputSignal_ || !certEvent_)
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
        DWORD count = freerdp_get_event_handles(context_, handles, MAXIMUM_WAIT_OBJECTS - 2);
        if (count == 0) {
            HMLOGE("freerdp_get_event_handles 失败");
            break;
        }
        handles[count++] = stopEvent_;
        handles[count++] = inputSignal_;

        const DWORD status = WaitForMultipleObjects(count, handles, FALSE, INFINITE);
        if (status == WAIT_FAILED)
            break;
        if (WaitForSingleObject(stopEvent_, 0) == WAIT_OBJECT_0)
            break;
        DrainInput();
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

void RdpSession::OnDesktopResize(uint32_t w, uint32_t h)
{
    desktopWidth_.store(w);
    desktopHeight_.store(h);
    std::lock_guard<std::mutex> lock(windowMutex_);
    geometryDirty_ = true;
}

// ---- 输入注入 ----

void RdpSession::PushInput(const InputEvent& event)
{
    if (!running_.load())
        return;
    {
        std::lock_guard<std::mutex> lock(inputMutex_);
        if (inputQueue_.size() > 512) // 背压：丢弃最旧的移动事件
            inputQueue_.pop_front();
        inputQueue_.push_back(event);
    }
    if (inputSignal_)
        SetEvent(inputSignal_);
}

void RdpSession::DrainInput()
{
    rdpInput* input = context_ ? context_->input : nullptr;
    if (!input)
        return;
    for (;;) {
        InputEvent event;
        {
            std::lock_guard<std::mutex> lock(inputMutex_);
            if (inputQueue_.empty())
                return;
            event = inputQueue_.front();
            inputQueue_.pop_front();
        }
        switch (event.kind) {
            case InputEvent::Kind::Mouse:
                freerdp_input_send_mouse_event(input, event.flags, event.x, event.y);
                break;
            case InputEvent::Kind::Scancode: {
                UINT16 flags = event.down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
                if (event.extended)
                    flags |= KBD_FLAGS_EXTENDED;
                freerdp_input_send_keyboard_event(input, flags, static_cast<UINT8>(event.code));
                break;
            }
            case InputEvent::Kind::Unicode:
                freerdp_input_send_unicode_keyboard_event(input, 0, event.code);
                freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_RELEASE, event.code);
                break;
        }
    }
}

bool RdpSession::MapToDesktop(float sx, float sy, uint16_t& dx, uint16_t& dy)
{
    const uint32_t dw = desktopWidth_.load();
    const uint32_t dh = desktopHeight_.load();
    uint64_t sw = 0;
    uint64_t sh = 0;
    {
        std::lock_guard<std::mutex> lock(windowMutex_);
        sw = surfaceWidth_;
        sh = surfaceHeight_;
    }
    if (dw == 0 || dh == 0 || sw == 0 || sh == 0)
        return false;
    float fx = sx * static_cast<float>(dw) / static_cast<float>(sw);
    float fy = sy * static_cast<float>(dh) / static_cast<float>(sh);
    fx = std::max(0.0f, std::min(fx, static_cast<float>(dw - 1)));
    fy = std::max(0.0f, std::min(fy, static_cast<float>(dh - 1)));
    dx = static_cast<uint16_t>(fx);
    dy = static_cast<uint16_t>(fy);
    return true;
}

void RdpSession::SendPointer(uint16_t flags, float surfaceX, float surfaceY)
{
    InputEvent event = {};
    event.kind = InputEvent::Kind::Mouse;
    event.flags = flags;
    if (!MapToDesktop(surfaceX, surfaceY, event.x, event.y))
        return;
    PushInput(event);
}

void RdpSession::SendWheel(int32_t delta, float surfaceX, float surfaceY)
{
    InputEvent event = {};
    event.kind = InputEvent::Kind::Mouse;
    MapToDesktop(surfaceX, surfaceY, event.x, event.y);

    int32_t remaining = delta;
    while (remaining != 0) {
        const int32_t step = std::max(-255, std::min(255, remaining));
        remaining -= step;
        // 滚动量为 9 位二补码（负值自带 PTR_FLAGS_WHEEL_NEGATIVE 位）
        const uint16_t magnitude =
            static_cast<uint16_t>((step >= 0 ? step : 0x200 + step) & WheelRotationMask);
        event.flags = PTR_FLAGS_WHEEL | magnitude;
        PushInput(event);
    }
}

void RdpSession::SendScancode(uint16_t scancode, bool extended, bool down)
{
    InputEvent event = {};
    event.kind = InputEvent::Kind::Scancode;
    event.code = scancode;
    event.extended = extended;
    event.down = down;
    PushInput(event);
}

void RdpSession::SendUnicode(uint16_t utf16Unit)
{
    InputEvent event = {};
    event.kind = InputEvent::Kind::Unicode;
    event.code = utf16Unit;
    PushInput(event);
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
