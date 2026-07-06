// HMRDP NAPI 模块入口：XComponent 接线 + 会话 API
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>

#include <freerdp/version.h>

#include "hm_log.h"
#include "input_mapper.h"
#include "rdp_session.h"

using hmrdp::RdpSession;
using hmrdp::SessionConfig;
using hmrdp::SessionState;

namespace {

std::mutex g_mutex;
std::unique_ptr<RdpSession> g_session;
OHNativeWindow* g_window = nullptr;
uint64_t g_surfaceW = 0;
uint64_t g_surfaceH = 0;
napi_threadsafe_function g_stateTsfn = nullptr;
napi_threadsafe_function g_certTsfn = nullptr;

struct StateEvent {
    int32_t state;
    std::string message;
};

struct CertEvent {
    std::string host;
    uint32_t port;
    std::string commonName;
    std::string subject;
    std::string issuer;
    std::string fingerprint;
    bool changed;
};

// ---- TSFN: RDP 线程 -> ArkTS ----

void CallJsStateCallback(napi_env env, napi_value jsCallback, void* /*context*/, void* data)
{
    std::unique_ptr<StateEvent> event(static_cast<StateEvent*>(data));
    if (!env || !jsCallback || !event)
        return;
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value args[2] = {};
    napi_create_int32(env, event->state, &args[0]);
    napi_create_string_utf8(env, event->message.c_str(), NAPI_AUTO_LENGTH, &args[1]);
    napi_call_function(env, undefined, jsCallback, 2, args, nullptr);
}

void OnSessionState(SessionState state, const char* message, void* /*userData*/)
{
    napi_threadsafe_function tsfn = nullptr;
    napi_threadsafe_function certTsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        tsfn = g_stateTsfn;
        if (state == SessionState::Disconnected) { // 最后一条消息之后释放
            g_stateTsfn = nullptr;
            certTsfn = g_certTsfn;
            g_certTsfn = nullptr;
        }
    }
    if (certTsfn)
        napi_release_threadsafe_function(certTsfn, napi_tsfn_release);
    if (!tsfn)
        return;
    auto* event = new StateEvent{ static_cast<int32_t>(state), message ? message : "" };
    if (napi_call_threadsafe_function(tsfn, event, napi_tsfn_blocking) != napi_ok)
        delete event;
    if (state == SessionState::Disconnected)
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
}

void CallJsCertCallback(napi_env env, napi_value jsCallback, void* /*context*/, void* data)
{
    std::unique_ptr<CertEvent> event(static_cast<CertEvent*>(data));
    if (!env || !jsCallback || !event)
        return;
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_value value = nullptr;
    napi_create_string_utf8(env, event->host.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, obj, "host", value);
    napi_create_uint32(env, event->port, &value);
    napi_set_named_property(env, obj, "port", value);
    napi_create_string_utf8(env, event->commonName.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, obj, "commonName", value);
    napi_create_string_utf8(env, event->subject.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, obj, "subject", value);
    napi_create_string_utf8(env, event->issuer.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, obj, "issuer", value);
    napi_create_string_utf8(env, event->fingerprint.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, obj, "fingerprint", value);
    napi_get_boolean(env, event->changed, &value);
    napi_set_named_property(env, obj, "changed", value);

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value args[1] = { obj };
    napi_call_function(env, undefined, jsCallback, 1, args, nullptr);
}

void OnCertRequest(const hmrdp::CertInfo& info, void* /*userData*/)
{
    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        tsfn = g_certTsfn;
    }
    if (!tsfn) {
        // 无 UI 处理方：直接拒绝，避免 RDP 线程等满超时
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->ProvideCertDecision(0);
        return;
    }
    auto* event = new CertEvent{ info.host ? info.host : "",     info.port,
                                 info.commonName ? info.commonName : "",
                                 info.subject ? info.subject : "",
                                 info.issuer ? info.issuer : "",
                                 info.fingerprint ? info.fingerprint : "",
                                 info.changed };
    if (napi_call_threadsafe_function(tsfn, event, napi_tsfn_blocking) != napi_ok)
        delete event;
}

// ---- XComponent 回调（UI 线程）----

void OnSurfaceCreated(OH_NativeXComponent* component, void* window)
{
    auto* nativeWindow = static_cast<OHNativeWindow*>(window);
    uint64_t w = 0;
    uint64_t h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    HMLOGI("surface created %{public}llu x %{public}llu", (unsigned long long)w, (unsigned long long)h);

    std::lock_guard<std::mutex> lock(g_mutex);
    g_window = nativeWindow;
    g_surfaceW = w;
    g_surfaceH = h;
    if (g_session)
        g_session->AttachWindow(nativeWindow, w, h);
}

void OnSurfaceChanged(OH_NativeXComponent* component, void* window)
{
    uint64_t w = 0;
    uint64_t h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    std::lock_guard<std::mutex> lock(g_mutex);
    g_surfaceW = w;
    g_surfaceH = h;
    if (g_session)
        g_session->AttachWindow(static_cast<OHNativeWindow*>(window), w, h);
}

void OnSurfaceDestroyed(OH_NativeXComponent* /*component*/, void* /*window*/)
{
    HMLOGI("surface destroyed");
    std::lock_guard<std::mutex> lock(g_mutex);
    g_window = nullptr;
    g_surfaceW = 0;
    g_surfaceH = 0;
    if (g_session)
        g_session->DetachWindow();
}

hmrdp::TouchMapper g_touchMapper;
std::atomic<bool> g_gestureActive{ false }; // ArkUI 缩放/平移手势进行中，暂停触摸转鼠标

RdpSession* CurrentSession()
{
    // 注意：调用方不持有生命周期；会话销毁只发生在 UI 线程 connect()，
    // 与本文件所有使用点同线程，因此裸指针安全。
    return g_session.get();
}

void DispatchTouchEvent(OH_NativeXComponent* component, void* window)
{
    OH_NativeXComponent_TouchEvent event;
    if (OH_NativeXComponent_GetTouchEvent(component, window, &event) != 0)
        return;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_gestureActive.load()) {
        g_touchMapper.Reset();
        return;
    }
    g_touchMapper.OnTouch(event, CurrentSession());
}

void DispatchMouseEvent(OH_NativeXComponent* component, void* window)
{
    OH_NativeXComponent_MouseEvent event;
    if (OH_NativeXComponent_GetMouseEvent(component, window, &event) != 0)
        return;
    std::lock_guard<std::mutex> lock(g_mutex);
    hmrdp::HandleMouse(event, CurrentSession());
}

void DispatchHoverEvent(OH_NativeXComponent* /*component*/, bool /*isHover*/) {}

void DispatchKeyEvent(OH_NativeXComponent* component, void* /*window*/)
{
    OH_NativeXComponent_KeyEvent* event = nullptr;
    if (OH_NativeXComponent_GetKeyEvent(component, &event) != 0 || !event)
        return;
    OH_NativeXComponent_KeyAction action;
    OH_NativeXComponent_KeyCode code;
    if (OH_NativeXComponent_GetKeyEventAction(event, &action) != 0 ||
        OH_NativeXComponent_GetKeyEventCode(event, &code) != 0)
        return;
    if (action != OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN && action != OH_NATIVEXCOMPONENT_KEY_ACTION_UP)
        return;

    uint16_t scancode = 0;
    bool extended = false;
    if (!hmrdp::OhosKeyToRdpScancode(static_cast<uint32_t>(code), scancode, extended))
        return;

    std::lock_guard<std::mutex> lock(g_mutex);
    RdpSession* session = CurrentSession();
    if (session)
        session->SendScancode(scancode, extended, action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN);
}

OH_NativeXComponent_Callback g_xcomponentCallbacks = {
    OnSurfaceCreated,
    OnSurfaceChanged,
    OnSurfaceDestroyed,
    DispatchTouchEvent,
};

OH_NativeXComponent_MouseEvent_Callback g_mouseCallbacks = {
    DispatchMouseEvent,
    DispatchHoverEvent,
};

// ---- NAPI 工具 ----

std::string GetStringProp(napi_env env, napi_value obj, const char* key, const char* fallback = "")
{
    napi_value value = nullptr;
    bool has = false;
    napi_has_named_property(env, obj, key, &has);
    if (!has || napi_get_named_property(env, obj, key, &value) != napi_ok)
        return fallback;
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok)
        return fallback;
    std::string out(len, '\0');
    napi_get_value_string_utf8(env, value, out.data(), len + 1, &len);
    return out;
}

uint32_t GetUint32Prop(napi_env env, napi_value obj, const char* key, uint32_t fallback)
{
    napi_value value = nullptr;
    bool has = false;
    napi_has_named_property(env, obj, key, &has);
    if (!has || napi_get_named_property(env, obj, key, &value) != napi_ok)
        return fallback;
    uint32_t out = fallback;
    if (napi_get_value_uint32(env, value, &out) != napi_ok)
        return fallback;
    return out;
}

// ---- 导出函数 ----

napi_value GetVersion(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, "FreeRDP " FREERDP_VERSION_FULL, NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value Connect(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result = nullptr;
    if (argc < 3) {
        napi_throw_error(env, nullptr, "connect(config, onState, onCert) 需要 3 个参数");
        return result;
    }

    SessionConfig config;
    config.host = GetStringProp(env, args[0], "host");
    config.port = static_cast<uint16_t>(GetUint32Prop(env, args[0], "port", 3389));
    config.username = GetStringProp(env, args[0], "username");
    config.password = GetStringProp(env, args[0], "password");
    config.domain = GetStringProp(env, args[0], "domain");
    config.width = GetUint32Prop(env, args[0], "width", 0);
    config.height = GetUint32Prop(env, args[0], "height", 0);
    config.scale = GetUint32Prop(env, args[0], "scale", 100);

    if (config.host.empty()) {
        napi_throw_error(env, nullptr, "host 不能为空");
        return result;
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_session && g_session->IsRunning()) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    if (g_session) {
        g_session->RequestStop();
        g_session->Join();
        g_session.reset();
    }
    if (g_stateTsfn) {
        napi_release_threadsafe_function(g_stateTsfn, napi_tsfn_release);
        g_stateTsfn = nullptr;
    }
    if (g_certTsfn) {
        napi_release_threadsafe_function(g_certTsfn, napi_tsfn_release);
        g_certTsfn = nullptr;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "hmrdpState", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_threadsafe_function(env, args[1], nullptr, resourceName, 0, 1, nullptr, nullptr,
                                        nullptr, CallJsStateCallback, &g_stateTsfn) != napi_ok) {
        napi_throw_error(env, nullptr, "创建状态回调失败");
        return result;
    }
    napi_create_string_utf8(env, "hmrdpCert", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_threadsafe_function(env, args[2], nullptr, resourceName, 0, 1, nullptr, nullptr,
                                        nullptr, CallJsCertCallback, &g_certTsfn) != napi_ok) {
        napi_release_threadsafe_function(g_stateTsfn, napi_tsfn_release);
        g_stateTsfn = nullptr;
        napi_throw_error(env, nullptr, "创建证书回调失败");
        return result;
    }

    g_session = std::make_unique<RdpSession>(std::move(config), OnSessionState, nullptr);
    g_session->SetCertCallback(OnCertRequest, nullptr);
    if (g_window)
        g_session->AttachWindow(g_window, g_surfaceW, g_surfaceH);

    const bool ok = g_session->Start();
    if (!ok) {
        g_session.reset();
        napi_release_threadsafe_function(g_stateTsfn, napi_tsfn_release);
        g_stateTsfn = nullptr;
        napi_release_threadsafe_function(g_certTsfn, napi_tsfn_release);
        g_certTsfn = nullptr;
    }
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value Disconnect(napi_env env, napi_callback_info /*info*/)
{
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->RequestStop();
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// setGestureActive(active: boolean) — 缩放/平移期间抑制触摸转鼠标
napi_value SetGestureActive(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool active = false;
    if (argc >= 1)
        napi_get_value_bool(env, args[0], &active);
    g_gestureActive.store(active);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// respondCert(decision: number)  0=拒绝 1=永久接受 2=仅本次
napi_value RespondCert(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t decision = 0;
    if (argc >= 1)
        napi_get_value_int32(env, args[0], &decision);

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->ProvideCertDecision(decision);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// sendUnicode(utf16Unit: number)
napi_value SendUnicode(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t code = 0;
    if (argc >= 1)
        napi_get_value_uint32(env, args[0], &code);

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->SendUnicode(static_cast<uint16_t>(code));
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// sendScancode(scancode: number, extended: boolean, down: boolean)
napi_value SendScancode(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t code = 0;
    bool extended = false;
    bool down = false;
    if (argc >= 3) {
        napi_get_value_uint32(env, args[0], &code);
        napi_get_value_bool(env, args[1], &extended);
        napi_get_value_bool(env, args[2], &down);
    }

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->SendScancode(static_cast<uint16_t>(code), extended, down);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

void RegisterXComponent(napi_env env, napi_value exports)
{
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) != napi_ok)
        return;
    OH_NativeXComponent* xcomponent = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&xcomponent)) != napi_ok || !xcomponent)
        return;
    OH_NativeXComponent_RegisterCallback(xcomponent, &g_xcomponentCallbacks);
    OH_NativeXComponent_RegisterMouseEventCallback(xcomponent, &g_mouseCallbacks);
    OH_NativeXComponent_RegisterKeyEventCallback(xcomponent, DispatchKeyEvent);
    HMLOGI("XComponent 回调注册完成");
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "disconnect", nullptr, Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendUnicode", nullptr, SendUnicode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendScancode", nullptr, SendScancode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "respondCert", nullptr, RespondCert, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setGestureActive", nullptr, SetGestureActive, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    RegisterXComponent(env, exports);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "hmrdp",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterHmrdpModule(void)
{
    napi_module_register(&g_module);
}
