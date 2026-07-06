// RDP 会话核心：包装 freerdp 客户端实例与事件循环线程
#ifndef HMRDP_RDP_SESSION_H
#define HMRDP_RDP_SESSION_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
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
};

// 状态回调：由 RDP 线程调用，实现方负责线程安全（NAPI 侧用 TSFN）
using StateCallback = void (*)(SessionState state, const char* message, void* userData);

class RdpSession {
public:
    RdpSession(SessionConfig config, StateCallback cb, void* cbUserData);
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

    // ---- 以下供 freerdp C 回调使用 ----
    void OnGraphicsDirty();                 // EndPaint：把 GDI 帧刷到 NativeWindow
    void OnDesktopResize(uint32_t w, uint32_t h);
    void NotifyState(SessionState state, const char* message);
    const SessionConfig& Config() const { return config_; }
    freerdp* Instance() const { return instance_; }

private:
    void ThreadMain();
    bool ApplySettings();
    bool PresentFrame(); // 全帧拷贝到 NativeWindow（含行 stride 处理）

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
};

} // namespace hmrdp

#endif // HMRDP_RDP_SESSION_H
