// HMRDP NAPI 模块入口：XComponent 接线 + 会话 API
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <multimodalinput/oh_input_manager.h>
#include <multimodalinput/oh_axis_type.h>

#include <atomic>

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
napi_threadsafe_function g_clipTsfn = nullptr;
napi_threadsafe_function g_clipImageTsfn = nullptr;
std::atomic<bool> g_keyIntercepting{ false };  // 物理键盘拦截是否生效（受限权限）
std::atomic<bool> g_touchEnabled{ true };     // 触摸→鼠标映射开关（PC 上关掉以避双击）

// ---- 返回鸿蒙桌面热键（本地消费，不转发远端；命中即回调 ArkTS 最小化窗口）----
// PC 全屏会话既没有标题栏悬浮也没有 Dock 悬浮，且键盘拦截器会吞掉鸿蒙自身的系统快捷键，
// 所以必须自己留一个键盘出口。
constexpr uint32_t kModCtrl = 0x1;
constexpr uint32_t kModAlt = 0x2;
constexpr uint32_t kModShift = 0x4;
// g_heldMods 按物理键分位记录，左右键分开：只按下两个 Ctrl 中的一个时抬起不会误清状态
constexpr uint32_t kHeldCtrlL = 1u << 0;
constexpr uint32_t kHeldCtrlR = 1u << 1;
constexpr uint32_t kHeldAltL = 1u << 2;
constexpr uint32_t kHeldAltR = 1u << 3;
constexpr uint32_t kHeldShiftL = 1u << 4;
constexpr uint32_t kHeldShiftR = 1u << 5;

napi_threadsafe_function g_desktopTsfn = nullptr;
std::atomic<uint32_t> g_desktopMods{ 0 };      // 需要的修饰键位掩码；0 = 未配置
std::atomic<int32_t> g_desktopKey{ 0 };        // 触发键的 OHOS 键码；0 = 未配置
std::atomic<uint32_t> g_heldMods{ 0 };         // 自行跟踪的修饰键按下态（物理键位）
std::atomic<int32_t> g_desktopSwallowUp{ 0 };  // 已吞掉 DOWN 的触发键，其 UP 也要吞
// 武装后是否已经收到过按键：只在第一次打一条日志，用来确认按键真的走到了我们这条路上。
// 不逐键打日志——那等于把用户的击键记进 hilog。
std::atomic<bool> g_desktopSawKey{ false };

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

void CallJsDesktopHotkeyCallback(napi_env env, napi_value jsCallback, void* /*context*/, void* /*data*/)
{
    if (!env || !jsCallback)
        return;
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCallback, 0, nullptr, nullptr);
}

void OnSessionState(SessionState state, const char* message, void* /*userData*/)
{
    napi_threadsafe_function tsfn = nullptr;
    napi_threadsafe_function certTsfn = nullptr;
    napi_threadsafe_function clipTsfn = nullptr;
    napi_threadsafe_function clipImageTsfn = nullptr;
    napi_threadsafe_function desktopTsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        tsfn = g_stateTsfn;
        if (state == SessionState::Disconnected) { // 最后一条消息之后释放
            g_stateTsfn = nullptr;
            certTsfn = g_certTsfn;
            g_certTsfn = nullptr;
            clipTsfn = g_clipTsfn;
            g_clipTsfn = nullptr;
            clipImageTsfn = g_clipImageTsfn;
            g_clipImageTsfn = nullptr;
            desktopTsfn = g_desktopTsfn; // 会话结束即摘热键回调；重连时 ArkTS 会重新下发
            g_desktopTsfn = nullptr;
        }
    }
    if (desktopTsfn)
        napi_release_threadsafe_function(desktopTsfn, napi_tsfn_release);
    if (certTsfn)
        napi_release_threadsafe_function(certTsfn, napi_tsfn_release);
    if (clipTsfn)
        napi_release_threadsafe_function(clipTsfn, napi_tsfn_release);
    if (clipImageTsfn)
        napi_release_threadsafe_function(clipImageTsfn, napi_tsfn_release);
    // 断开兜底：即便 ArkTS 漏调也要释放键盘拦截器，避免输入设备被卡住
    if (state == SessionState::Disconnected && g_keyIntercepting.exchange(false))
        OH_Input_RemoveKeyEventInterceptor();
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

// ---- TSFN: 远端剪贴板文本 -> ArkTS ----

void CallJsClipCallback(napi_env env, napi_value jsCallback, void* /*context*/, void* data)
{
    std::unique_ptr<std::string> text(static_cast<std::string*>(data));
    if (!env || !jsCallback || !text)
        return;
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value arg = nullptr;
    napi_create_string_utf8(env, text->c_str(), NAPI_AUTO_LENGTH, &arg);
    napi_value args[1] = { arg };
    napi_call_function(env, undefined, jsCallback, 1, args, nullptr);
}

void OnClipboardText(const char* utf8Text, void* /*userData*/)
{
    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        tsfn = g_clipTsfn;
    }
    if (!tsfn)
        return;
    auto* text = new std::string(utf8Text ? utf8Text : "");
    if (napi_call_threadsafe_function(tsfn, text, napi_tsfn_blocking) != napi_ok)
        delete text;
}

// ---- TSFN: 远端剪贴板图片(PNG) -> ArkTS ----

void CallJsClipImageCallback(napi_env env, napi_value jsCallback, void* /*context*/, void* data)
{
    std::unique_ptr<std::vector<uint8_t>> png(static_cast<std::vector<uint8_t>*>(data));
    if (!env || !jsCallback || !png || png->empty())
        return;
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value arraybuffer = nullptr;
    void* outBuf = nullptr;
    if (napi_create_arraybuffer(env, png->size(), &outBuf, &arraybuffer) != napi_ok)
        return;
    memcpy(outBuf, png->data(), png->size());
    napi_value uint8 = nullptr;
    if (napi_create_typedarray(env, napi_uint8_array, png->size(), arraybuffer, 0, &uint8) != napi_ok)
        return;
    napi_value args[1] = { uint8 };
    napi_call_function(env, undefined, jsCallback, 1, args, nullptr);
}

void OnClipboardImage(const uint8_t* data, size_t len, void* /*userData*/)
{
    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        tsfn = g_clipImageTsfn;
    }
    if (!tsfn || !data || len == 0)
        return;
    auto* png = new std::vector<uint8_t>(data, data + len);
    if (napi_call_threadsafe_function(tsfn, png, napi_tsfn_blocking) != napi_ok)
        delete png;
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
    if (g_session) {
        g_session->AttachWindow(nativeWindow, w, h);
        if (g_session->IsDynamicResolution())
            g_session->RequestResize(static_cast<uint32_t>(w), static_cast<uint32_t>(h));
    }
}

void OnSurfaceChanged(OH_NativeXComponent* component, void* window)
{
    uint64_t w = 0;
    uint64_t h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    auto* nativeWindow = static_cast<OHNativeWindow*>(window);
    std::lock_guard<std::mutex> lock(g_mutex);
    // 外接显示器在位时系统可能高频重复上报同尺寸的 surfaceChanged；
    // 窗口与尺寸都没变就直接忽略，避免反复 Attach/Resize 造成画面闪烁。
    if (nativeWindow == g_window && w == g_surfaceW && h == g_surfaceH)
        return;
    HMLOGI("surface changed %{public}llu x %{public}llu (旧 %{public}llu x %{public}llu)",
           (unsigned long long)w, (unsigned long long)h,
           (unsigned long long)g_surfaceW, (unsigned long long)g_surfaceH);
    g_window = nativeWindow;
    g_surfaceW = w;
    g_surfaceH = h;
    if (g_session) {
        g_session->AttachWindow(nativeWindow, w, h);
        if (g_session->IsDynamicResolution())
            g_session->RequestResize(static_cast<uint32_t>(w), static_cast<uint32_t>(h));
    }
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

// 该物理修饰键在 g_heldMods 里占的位；0 = 不是修饰键
uint32_t PhysicalModBit(int32_t code)
{
    switch (code) {
        case KEY_CTRL_LEFT:   return kHeldCtrlL;
        case KEY_CTRL_RIGHT:  return kHeldCtrlR;
        case KEY_ALT_LEFT:    return kHeldAltL;
        case KEY_ALT_RIGHT:   return kHeldAltR;
        case KEY_SHIFT_LEFT:  return kHeldShiftL;
        case KEY_SHIFT_RIGHT: return kHeldShiftR;
        default:              return 0;
    }
}

// 物理键位 -> Ctrl/Alt/Shift 三位掩码（与 ArkTS 侧 MOD_* 约定一致）
uint32_t FoldMods(uint32_t held)
{
    uint32_t mods = 0;
    if ((held & (kHeldCtrlL | kHeldCtrlR)) != 0)
        mods |= kModCtrl;
    if ((held & (kHeldAltL | kHeldAltR)) != 0)
        mods |= kModAlt;
    if ((held & (kHeldShiftL | kHeldShiftR)) != 0)
        mods |= kModShift;
    return mods;
}

// 远端此刻已经收到过修饰键的按下（修饰键照常转发），命中热键后必须补发抬起，
// 否则我们吞掉后续按键、远端会一直以为 Ctrl/Shift 还按着。
void ReleaseRemoteModifiers(uint32_t held)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_session)
        return;
    if ((held & kHeldCtrlL) != 0)
        g_session->SendScancode(0x1D, false, false);
    if ((held & kHeldCtrlR) != 0)
        g_session->SendScancode(0x1D, true, false);
    if ((held & kHeldAltL) != 0)
        g_session->SendScancode(0x38, false, false);
    if ((held & kHeldAltR) != 0)
        g_session->SendScancode(0x38, true, false);
    if ((held & kHeldShiftL) != 0)
        g_session->SendScancode(0x2A, false, false);
    if ((held & kHeldShiftR) != 0)
        g_session->SendScancode(0x36, false, false);
}

// 直接问系统某个键此刻是否按下。比自行跟踪可靠：拦截器/XComponent 未必把每个修饰键的
// 按下抬起都送到我们这条路上（漏一个 DOWN 就永远匹配不上）。查询失败返回 false。
bool IsKeyPressed(int32_t code)
{
    Input_KeyState* state = OH_Input_CreateKeyState();
    if (!state)
        return false;
    OH_Input_SetKeyCode(state, code);
    bool pressed = false;
    if (OH_Input_GetKeyState(state) == INPUT_SUCCESS)
        pressed = (OH_Input_GetKeyPressed(state) == KEY_PRESSED);
    OH_Input_DestroyKeyState(&state);
    return pressed;
}

// 当前按住的修饰键（物理键位）：以系统查询为准，并上自行跟踪的结果兜底
uint32_t CurrentHeldMods()
{
    uint32_t held = g_heldMods.load();
    if (IsKeyPressed(KEY_CTRL_LEFT))
        held |= kHeldCtrlL;
    if (IsKeyPressed(KEY_CTRL_RIGHT))
        held |= kHeldCtrlR;
    if (IsKeyPressed(KEY_ALT_LEFT))
        held |= kHeldAltL;
    if (IsKeyPressed(KEY_ALT_RIGHT))
        held |= kHeldAltR;
    if (IsKeyPressed(KEY_SHIFT_LEFT))
        held |= kHeldShiftL;
    if (IsKeyPressed(KEY_SHIFT_RIGHT))
        held |= kHeldShiftR;
    return held;
}

// 返回鸿蒙桌面热键判定。返回 true = 该按键被本地消费，调用方不要再转发远端。
// 调用时不得持有 g_mutex（内部会取）。修饰键本身永远照常转发，否则远端组合键全废。
bool ConsumeDesktopHotkey(int32_t code, bool down)
{
    const uint32_t bit = PhysicalModBit(code);
    if (bit != 0) {
        if (down)
            g_heldMods.fetch_or(bit);
        else
            g_heldMods.fetch_and(~bit);
        return false;
    }
    const int32_t hotkey = g_desktopKey.load();
    const uint32_t wantMods = g_desktopMods.load();
    if (hotkey == 0 || wantMods == 0)
        return false;
    if (down && !g_desktopSawKey.exchange(true))
        HMLOGI("返回桌面热键: 已开始收到按键(首个 code=%{public}d)，判定链路通", code);
    if (!down) {
        if (g_desktopSwallowUp.load() == code) { // 吞掉命中键的抬起，别给远端留一个孤立 UP
            g_desktopSwallowUp.store(0);
            return true;
        }
        return false;
    }
    // 命中后按住不放的自动重复：一并吞掉。此时 g_heldMods 已清零、匹配不上了，
    // 不拦住的话这些重复会当普通按键发给远端（最小化失败的设备上尤其明显）
    if (g_desktopSwallowUp.load() == code)
        return true;
    if (code != hotkey)
        return false;

    const uint32_t held = CurrentHeldMods();
    const uint32_t mods = FoldMods(held);
    if (mods != wantMods) {
        // 触发键对上了但修饰键不符：把实际值打出来，便于定位「热键怎么按都不响」
        HMLOGI("返回桌面热键未命中: code=%{public}d 期望mods=%{public}u 实际mods=%{public}u held=0x%{public}x",
               code, wantMods, mods, held);
        return false;
    }

    g_heldMods.store(0); // 已告知远端全部抬起，按干净状态重新计
    ReleaseRemoteModifiers(held);
    g_desktopSwallowUp.store(code);

    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        tsfn = g_desktopTsfn;
    }
    if (tsfn)
        napi_call_threadsafe_function(tsfn, nullptr, napi_tsfn_nonblocking);
    HMLOGI("返回桌面热键命中: code=%{public}d mods=%{public}u 回调=%{public}d", code, wantMods,
           tsfn != nullptr ? 1 : 0);
    return true;
}

void DispatchTouchEvent(OH_NativeXComponent* component, void* window)
{
    if (!g_touchEnabled.load())
        return; // PC/2in1 有物理键鼠，触摸由 ArkTS 手势处理，不走 TouchMapper 避免双击
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
    if (g_keyIntercepting.load())
        return; // 全局拦截器已接管物理键盘，避免与 XComponent 路径重复发送
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

    // 未拿到 INTERCEPT_INPUT_EVENT 权限时按键走这条路，返回桌面热键同样要生效
    if (ConsumeDesktopHotkey(static_cast<int32_t>(code), action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN))
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
    size_t argc = 5;
    napi_value args[5] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result = nullptr;
    if (argc < 3) {
        napi_throw_error(env, nullptr, "connect(config, onState, onCert[, onClip[, onClipImage]]) 需要至少 3 个参数");
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
    config.dynamicResolution = GetUint32Prop(env, args[0], "dynamic", 0) != 0;
    // drives: Array<{ name: string, path: string }>
    napi_value drivesVal = nullptr;
    bool hasDrives = false;
    napi_has_named_property(env, args[0], "drives", &hasDrives);
    if (hasDrives && napi_get_named_property(env, args[0], "drives", &drivesVal) == napi_ok) {
        bool isArray = false;
        napi_is_array(env, drivesVal, &isArray);
        if (isArray) {
            uint32_t len = 0;
            napi_get_array_length(env, drivesVal, &len);
            for (uint32_t i = 0; i < len; i++) {
                napi_value el = nullptr;
                if (napi_get_element(env, drivesVal, i, &el) != napi_ok)
                    continue;
                SessionConfig::DriveMount dm;
                dm.name = GetStringProp(env, el, "name", "HMRDP");
                dm.path = GetStringProp(env, el, "path");
                if (!dm.path.empty())
                    config.drives.push_back(dm);
            }
        }
    }
    HMLOGI("磁盘重定向: 收到 %{public}zu 个共享盘", config.drives.size());
    for (size_t i = 0; i < config.drives.size(); i++) {
        HMLOGI("  盘[%{public}zu] name=%{public}s path=%{public}s", i,
               config.drives[i].name.c_str(), config.drives[i].path.c_str());
    }

    if (config.host.empty()) {
        napi_throw_error(env, nullptr, "host 不能为空");
        return result;
    }

    // 先在锁外拆除旧会话：其 RDP 线程的回调也会取 g_mutex，
    // 若持锁 Join 会与线程末尾的 NotifyState(Disconnected) 死锁。
    std::unique_ptr<RdpSession> oldSession;
    napi_threadsafe_function oldState = nullptr;
    napi_threadsafe_function oldCert = nullptr;
    napi_threadsafe_function oldClip = nullptr;
    napi_threadsafe_function oldClipImage = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session && g_session->IsRunning()) {
            napi_get_boolean(env, false, &result);
            return result;
        }
        oldSession = std::move(g_session);
        oldState = g_stateTsfn;
        oldCert = g_certTsfn;
        oldClip = g_clipTsfn;
        oldClipImage = g_clipImageTsfn;
        g_stateTsfn = nullptr;
        g_certTsfn = nullptr;
        g_clipTsfn = nullptr;
        g_clipImageTsfn = nullptr;
    }
    if (oldSession) {
        oldSession->RequestStop();
        oldSession->Join(); // Join 后旧线程再无回调，释放 tsfn 才安全
    }
    oldSession.reset();
    if (oldState)
        napi_release_threadsafe_function(oldState, napi_tsfn_release);
    if (oldCert)
        napi_release_threadsafe_function(oldCert, napi_tsfn_release);
    if (oldClip)
        napi_release_threadsafe_function(oldClip, napi_tsfn_release);
    if (oldClipImage)
        napi_release_threadsafe_function(oldClipImage, napi_tsfn_release);

    std::lock_guard<std::mutex> lock(g_mutex);

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
    // 剪贴板回调（可选第 4 参）：失败仅降级剪贴板，不影响连接
    if (argc >= 4) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[3], &vt);
        if (vt == napi_function) {
            napi_create_string_utf8(env, "hmrdpClip", NAPI_AUTO_LENGTH, &resourceName);
            if (napi_create_threadsafe_function(env, args[3], nullptr, resourceName, 0, 1, nullptr,
                                                nullptr, nullptr, CallJsClipCallback,
                                                &g_clipTsfn) != napi_ok)
                g_clipTsfn = nullptr;
        }
    }
    // 图片剪贴板回调（可选第 5 参）：失败仅降级，不影响连接
    if (argc >= 5) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[4], &vt);
        if (vt == napi_function) {
            napi_create_string_utf8(env, "hmrdpClipImage", NAPI_AUTO_LENGTH, &resourceName);
            if (napi_create_threadsafe_function(env, args[4], nullptr, resourceName, 0, 1, nullptr,
                                                nullptr, nullptr, CallJsClipImageCallback,
                                                &g_clipImageTsfn) != napi_ok)
                g_clipImageTsfn = nullptr;
        }
    }

    g_session = std::make_unique<RdpSession>(std::move(config), OnSessionState, nullptr);
    g_session->SetCertCallback(OnCertRequest, nullptr);
    g_session->SetClipCallback(OnClipboardText, nullptr);
    g_session->SetClipImageCallback(OnClipboardImage, nullptr);
    if (g_window)
        g_session->AttachWindow(g_window, g_surfaceW, g_surfaceH);

    const bool ok = g_session->Start();
    if (!ok) {
        g_session.reset();
        napi_release_threadsafe_function(g_stateTsfn, napi_tsfn_release);
        g_stateTsfn = nullptr;
        napi_release_threadsafe_function(g_certTsfn, napi_tsfn_release);
        g_certTsfn = nullptr;
        if (g_clipTsfn) {
            napi_release_threadsafe_function(g_clipTsfn, napi_tsfn_release);
            g_clipTsfn = nullptr;
        }
        if (g_clipImageTsfn) {
            napi_release_threadsafe_function(g_clipImageTsfn, napi_tsfn_release);
            g_clipImageTsfn = nullptr;
        }
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

// setTouchMode(trackpad: boolean) — false 直接触摸 / true 触控板
napi_value SetTouchMode(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool trackpad = false;
    if (argc >= 1)
        napi_get_value_bool(env, args[0], &trackpad);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_touchMapper.SetTrackpadMode(trackpad);
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

// requestResize(width: number, height: number) — 动态分辨率：请求远端桌面尺寸
napi_value RequestResize(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t w = 0;
    uint32_t h = 0;
    if (argc >= 2) {
        napi_get_value_uint32(env, args[0], &w);
        napi_get_value_uint32(env, args[1], &h);
    }
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->RequestResize(w, h);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// setClipboardText(text: string) — 本地剪贴板文本变更，向远端广告
napi_value SetClipboardText(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string text;
    if (argc >= 1) {
        size_t len = 0;
        if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &len) == napi_ok) {
            text.resize(len);
            napi_get_value_string_utf8(env, args[0], text.data(), len + 1, &len);
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->SetLocalClipboardText(text.c_str());
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// setClipboardImage(bytes: Uint8Array) - 本地剪贴板图片(PNG)变更，向远端广告图片格式
napi_value SetClipboardImage(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        size_t offset = 0;
        size_t len = 0;
        void* data = nullptr;
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[0], &vt);
        if (vt == napi_object) {
            bool isView = false;
            napi_is_typedarray(env, args[0], &isView);
            if (isView) {
                napi_typedarray_type type = napi_uint8_array;
                size_t byteLength = 0;
                napi_value ab = nullptr;
                if (napi_get_typedarray_info(env, args[0], &type, &byteLength, &data, &ab, &offset) == napi_ok &&
                    type == napi_uint8_array)
                    len = byteLength;
            } else {
                bool isAb = false;
                napi_is_arraybuffer(env, args[0], &isAb);
                if (isAb && napi_get_arraybuffer_info(env, args[0], &data, &len) == napi_ok)
                    offset = 0;
            }
        }
        if (data && len > 0) {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_session)
                g_session->SetLocalClipboardImage(static_cast<const uint8_t*>(data) + offset, len);
        }
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ---- 物理键盘拦截（受限权限 INTERCEPT_INPUT_EVENT）----
// 拦截器全局生效、消费按键；会话聚焦时开启，把含 Win 的全键盘转发远端，失焦/断开时关闭。
void OnInterceptedKey(const Input_KeyEvent* keyEvent)
{
    if (!keyEvent)
        return;
    const int32_t action = OH_Input_GetKeyEventAction(keyEvent);
    if (action != KEY_ACTION_DOWN && action != KEY_ACTION_UP)
        return;
    const int32_t code = OH_Input_GetKeyEventKeyCode(keyEvent);
    // 拦截器把鸿蒙自身的系统快捷键也吞了，返回桌面热键是全屏会话里唯一的键盘出口
    if (ConsumeDesktopHotkey(code, action == KEY_ACTION_DOWN))
        return;
    uint16_t scancode = 0;
    bool extended = false;
    if (!hmrdp::OhosKeyToRdpScancode(static_cast<uint32_t>(code), scancode, extended))
        return;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_session)
        g_session->SendScancode(scancode, extended, action == KEY_ACTION_DOWN);
}

// 鼠标滚轮已改由 ArkTS onAxisEvent -> sendWheel 转发（见 SessionPage.ets）。
// 不再用 OH_Input_AddInputEventInterceptor：该拦截器一旦注册即全局消费
// mouse/touch/axis（回调为 null 即静默丢弃），会令鼠标点击与触摸全部失效。

// setTouchEnabled(enable: boolean) — PC 上关闭触摸映射，避免和物理鼠标产生双击
napi_value SetTouchEnabled(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enable = true;
    if (argc >= 1)
        napi_get_value_bool(env, args[0], &enable);
    g_touchEnabled.store(enable);
    if (!enable) {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_touchMapper.Reset();
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// sendWheel(delta: number, surfaceX: number, surfaceY: number) — 鼠标滚轮（ArkTS onMouse 接过来）
napi_value SendWheel(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t delta = 0;
    float x = 0;
    float y = 0;
    if (argc >= 3) {
        napi_get_value_int32(env, args[0], &delta);
        double v = 0;
        napi_get_value_double(env, args[1], &v);
        x = static_cast<float>(v);
        napi_get_value_double(env, args[2], &v);
        y = static_cast<float>(v);
    }
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_session)
            g_session->SendWheel(delta, x, y);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// setKeyInterception(enable) — 返回是否处于拦截态（无受限权限时恒 false，自动降级）
napi_value SetKeyInterception(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enable = false;
    if (argc >= 1)
        napi_get_value_bool(env, args[0], &enable);

    if (enable && !g_keyIntercepting.load()) {
        const Input_Result rc = OH_Input_AddKeyEventInterceptor(OnInterceptedKey, nullptr);
        if (rc == INPUT_SUCCESS)
            g_keyIntercepting.store(true);
        else
            HMLOGW("键盘拦截未启用(rc=%{public}d)", rc);
        // 滚轮不再用全局拦截器（会吞掉鼠标/触摸），改由 ArkTS onAxisEvent 转发。
    } else if (!enable && g_keyIntercepting.load()) {
        OH_Input_RemoveKeyEventInterceptor();
        g_keyIntercepting.store(false);
    }

    // 拦截器开关切换时清空修饰键按下态：失焦期间的抬起我们收不到，留着会导致下次误判
    g_heldMods.store(0);
    g_desktopSwallowUp.store(0);

    napi_value result = nullptr;
    napi_get_boolean(env, g_keyIntercepting.load(), &result);
    return result;
}

// setDesktopHotkey(mods, keyCode, onTrigger?) — 会话返回桌面热键。
// mods 位掩码 1=Ctrl 2=Alt 4=Shift；mods 或 keyCode 为 0 = 关闭。命中的按键不再转发远端。
napi_value SetDesktopHotkey(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t mods = 0;
    int32_t keyCode = 0;
    if (argc >= 1)
        napi_get_value_uint32(env, args[0], &mods);
    if (argc >= 2)
        napi_get_value_int32(env, args[1], &keyCode);

    // 先摘旧回调再换配置：释放要在锁外做，避免与 TSFN 回调争锁
    napi_threadsafe_function old = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        old = g_desktopTsfn;
        g_desktopTsfn = nullptr;
    }
    if (old)
        napi_release_threadsafe_function(old, napi_tsfn_release);

    const bool enable = (mods != 0 && keyCode != 0);
    g_desktopMods.store(enable ? mods : 0);
    g_desktopKey.store(enable ? keyCode : 0);
    g_heldMods.store(0);
    g_desktopSwallowUp.store(0);
    g_desktopSawKey.store(false);
    if (enable && argc >= 3) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[2], &vt);
        if (vt == napi_function) {
            napi_value resourceName = nullptr;
            napi_create_string_utf8(env, "hmrdpDesktopHotkey", NAPI_AUTO_LENGTH, &resourceName);
            std::lock_guard<std::mutex> lock(g_mutex);
            if (napi_create_threadsafe_function(env, args[2], nullptr, resourceName, 0, 1, nullptr,
                                                nullptr, nullptr, CallJsDesktopHotkeyCallback,
                                                &g_desktopTsfn) != napi_ok)
                g_desktopTsfn = nullptr; // 创建失败仅热键失效，不影响会话
        }
    }
    HMLOGI("返回桌面热键: enable=%{public}d mods=%{public}u code=%{public}d", enable ? 1 : 0, mods, keyCode);

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
        { "setTouchMode", nullptr, SetTouchMode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "requestResize", nullptr, RequestResize, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setClipboardText", nullptr, SetClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setClipboardImage", nullptr, SetClipboardImage, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setKeyInterception", nullptr, SetKeyInterception, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setDesktopHotkey", nullptr, SetDesktopHotkey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setTouchEnabled", nullptr, SetTouchEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendWheel", nullptr, SendWheel, nullptr, nullptr, nullptr, napi_default, nullptr },
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
