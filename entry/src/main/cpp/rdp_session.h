// RDP 会话核心：包装 freerdp 客户端实例与事件循环线程
#ifndef HMRDP_RDP_SESSION_H
#define HMRDP_RDP_SESSION_H

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cliprdr.h>
#include <native_window/external_window.h>

namespace hmrdp {

// 与 ArkTS 侧约定的会话状态
enum class SessionState : int32_t {
    Connecting = 0,
    Connected = 1,
    Disconnected = 2,
};

struct SessionConfig {
    std::string host;
    uint16_t port = 3389;
    std::string username;
    std::string password;
    std::string domain;
    uint32_t width = 0;   // 0 = 跟随 surface 尺寸
    uint32_t height = 0;
    uint32_t scale = 100; // DesktopScaleFactor 百分比 [100,500]
    bool dynamicResolution = false; // true: 启用 disp 显示控制，远端分辨率跟随本机窗口
    std::string driveName;          // 磁盘重定向：远端显示名（空=不重定向）
    std::string drivePath;          // 磁盘重定向：本地目录绝对路径
};

// 状态回调：由 RDP 线程调用，实现方负责线程安全（NAPI 侧用 TSFN）
using StateCallback = void (*)(SessionState state, const char* message, void* userData);

// 证书确认请求：由 RDP 线程调用后阻塞等待 ProvideCertDecision
struct CertInfo {
    const char* host;
    uint16_t port;
    const char* commonName;
    const char* subject;
    const char* issuer;
    const char* fingerprint;
    bool changed;
};
using CertCallback = void (*)(const CertInfo& info, void* userData);

// 远端剪贴板文本 -> ArkTS（RDP 线程调用，实现方负责线程安全）
using ClipCallback = void (*)(const char* utf8Text, void* userData);

class RdpSession {
public:
    RdpSession(SessionConfig config, StateCallback cb, void* cbUserData);
    void SetCertCallback(CertCallback cb, void* userData);
    void SetClipCallback(ClipCallback cb, void* userData);
    // ArkTS：本地剪贴板文本变更时调用（任意线程），触发向远端广告文本格式
    void SetLocalClipboardText(const char* utf8Text);
    ~RdpSession();

    RdpSession(const RdpSession&) = delete;
    RdpSession& operator=(const RdpSession&) = delete;

    // 启动会话线程；失败返回 false（不会触发回调）
    bool Start();
    // 请求断开（异步，线程自行清理后回调 Disconnected）
    void RequestStop();
    // 等待会话线程结束（析构前调用）
    void Join();

    // surface 生命周期（UI/XComponent 线程调用）
    void AttachWindow(OHNativeWindow* window, uint64_t width, uint64_t height);
    void DetachWindow();

    bool IsRunning() const { return running_.load(); }

    // ---- 输入注入（任意线程调用，经队列转发到 RDP 线程）----
    // surface 像素坐标（内部换算为远端桌面坐标）
    void SendPointer(uint16_t flags, float surfaceX, float surfaceY);
    // 直接以远端桌面坐标发送（触控板虚拟指针用）
    void SendPointerDesktop(uint16_t flags, uint16_t desktopX, uint16_t desktopY);
    // delta: 正值向上滚动，单位为标准滚轮档（120/档）
    void SendWheel(int32_t delta, float surfaceX, float surfaceY);
    void SendScancode(uint16_t scancode, bool extended, bool down);
    void SendUnicode(uint16_t utf16Unit); // 自动发送按下+抬起

    void GetDesktopSize(uint32_t& w, uint32_t& h) const
    {
        w = desktopWidth_.load();
        h = desktopHeight_.load();
    }

    bool IsDynamicResolution() const { return config_.dynamicResolution; }
    // 动态分辨率：请求把远端桌面调整为 w×h（任意线程；经 disp 通道在 RDP 线程下发）
    void RequestResize(uint32_t w, uint32_t h);
    // disp 显示控制通道就绪/断开（RDP 线程，通道连接事件）
    void OnDispConnected(DispClientContext* disp);

    // ---- 以下供 freerdp C 回调使用（均在 RDP 线程）----
    void MarkDirty(int32_t x, int32_t y, int32_t w, int32_t h); // EndPaint 累积脏区
    void PresentIfDirty();                                       // 每轮事件后合并提交一次
    void OnDesktopResize(uint32_t w, uint32_t h);
    void NotifyState(SessionState state, const char* message);
    // RDP 线程调用：通知 UI 并阻塞等待决策（0 拒绝 / 1 永久接受 / 2 本次接受）
    uint32_t RequestCertDecision(const CertInfo& info);
    // 任意线程调用：投递用户决策
    void ProvideCertDecision(int32_t decision);
    // cliprdr 剪贴板通道就绪/断开（RDP 线程，通道连接事件）
    void OnCliprdrConnected(CliprdrClientContext* cliprdr);
    void OnCliprdrDisconnected();
    // 以下供 cliprdr 静态回调使用（均在 RDP 线程）
    void SendClipboardFormatList();                       // 向远端广告本地格式
    bool CopyLocalClipboardUtf8(std::string& out);        // 取本地剪贴板文本（UTF-8）
    void DeliverRemoteClipboard(const std::string& utf8); // 远端文本 -> ArkTS
    CliprdrClientContext* Cliprdr() const { return cliprdr_; }
    const SessionConfig& Config() const { return config_; }
    freerdp* Instance() const { return instance_; }

private:
    struct InputEvent {
        enum class Kind : uint8_t { Mouse, Scancode, Unicode };
        Kind kind;
        uint16_t flags;
        uint16_t x;
        uint16_t y;
        uint16_t code;
        bool extended;
        bool down;
    };

    void ThreadMain();
    bool ApplySettings();
    bool PresentFrame(); // 全帧拷贝到 NativeWindow（含行 stride 处理）
    void PushInput(const InputEvent& event);
    void DrainInput();
    bool MapToDesktop(float sx, float sy, uint16_t& dx, uint16_t& dy);
    void SendResizeIfPending();         // RDP 线程：有待定尺寸则经 disp 下发布局
    void AdvertiseClipboardIfPending(); // RDP 线程：本地剪贴板有更新则广告格式

    SessionConfig config_;
    StateCallback stateCb_;
    void* stateCbUserData_;

    rdpContext* context_ = nullptr;
    freerdp* instance_ = nullptr;
    HANDLE stopEvent_ = nullptr;

    std::thread thread_;
    std::atomic<bool> running_{ false };

    std::mutex windowMutex_;
    OHNativeWindow* window_ = nullptr;
    uint64_t surfaceWidth_ = 0;
    uint64_t surfaceHeight_ = 0;
    bool geometryDirty_ = true;

    std::atomic<uint32_t> desktopWidth_{ 0 };
    std::atomic<uint32_t> desktopHeight_{ 0 };

    // disp 动态分辨率（disp_ 仅 RDP 线程访问）
    DispClientContext* disp_ = nullptr;
    std::atomic<uint32_t> pendingW_{ 0 };
    std::atomic<uint32_t> pendingH_{ 0 };
    std::atomic<bool> resizePending_{ false };
    uint32_t layoutScale_ = 100;

    // cliprdr 剪贴板（cliprdr_ 仅 RDP 线程访问）
    CliprdrClientContext* cliprdr_ = nullptr;
    std::mutex clipMutex_;
    std::string localClipUtf8_;
    bool haveLocalClip_ = false;
    std::atomic<bool> advertisePending_{ false };
    ClipCallback clipCb_ = nullptr;
    void* clipCbUserData_ = nullptr;

    // 脏区累积（仅 RDP 线程访问）
    bool presentPending_ = false;
    int32_t dirtyX0_ = 0;
    int32_t dirtyY0_ = 0;
    int32_t dirtyX1_ = 0;
    int32_t dirtyY1_ = 0;

    std::mutex inputMutex_;
    std::deque<InputEvent> inputQueue_;
    HANDLE inputSignal_ = nullptr;

    CertCallback certCb_ = nullptr;
    void* certCbUserData_ = nullptr;
    HANDLE certEvent_ = nullptr;
    std::atomic<int32_t> certDecision_{ 0 };
};

} // namespace hmrdp

#endif // HMRDP_RDP_SESSION_H
