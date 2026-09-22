// 输入映射：OHOS 触摸/鼠标/键盘事件 -> RDP 输入
#ifndef HMRDP_INPUT_MAPPER_H
#define HMRDP_INPUT_MAPPER_H

#include <cstdint>

#include <ace/xcomponent/native_interface_xcomponent.h>

namespace hmrdp {

class RdpSession;

// OHOS 键码 -> RDP 扫描码（PS/2 set 1）；不支持的键返回 false
bool OhosKeyToRdpScancode(uint32_t ohosKeyCode, uint16_t& scancode, bool& extended);

// 触摸手势状态机（直接触摸模式）：
// - 单指点按 = 左键单击（抬起时发送，避免误触）
// - 单指按住拖动 = 左键拖拽
// - 双指纵向滑动 = 滚轮
// - 双指轻点 = 右键单击
class TouchMapper {
public:
    void OnTouch(const OH_NativeXComponent_TouchEvent& event, RdpSession* session);
    void Reset();
    // ArkUI 手势接管触摸时调用：拖拽中已按下的左键要补抬起，否则远端一直按着
    void Cancel(RdpSession* session);
    // ArkTS 侧长按计时满：在当前位置发一次右键。直接触摸模式落在手指处，触控板模式落在
    // 虚拟指针处。发完作废本次触摸序列，抬起时不再补那一下左键单击
    void LongPressRightClick(float surfaceX, float surfaceY, RdpSession* session);
    // 单指按住且未明显漂移的持续时间（纳秒）；不满足返回 -1，满足时带出按下点（surface px）。
    // ArkTS 侧靠轮询它画长按进度圈——XComponent 挂了 native 渲染后，ArkUI 的 onTouch
    // 收不到触摸事件，只有原生这条回调是通的
    int64_t HoldDurationNs(float& outX, float& outY) const;
    bool IsTrackpad() const { return trackpad_; }
    // false = 直接触摸模式，true = 触控板（相对指针）模式
    void SetTrackpadMode(bool trackpad);

private:
    enum class Mode : uint8_t { Idle, Pending, LeftDrag, TwoFinger };

    void UpdateHold(const OH_NativeXComponent_TouchEvent& event);
    void OnTouchDirect(const OH_NativeXComponent_TouchEvent& event, RdpSession* session);
    void OnTouchTrackpad(const OH_NativeXComponent_TouchEvent& event, RdpSession* session);
    void SyncCursor(RdpSession* session);
    void SendCursorMove(RdpSession* session);

    bool trackpad_ = false;
    Mode mode_ = Mode::Idle;
    float downX_ = 0;
    float downY_ = 0;
    float lastX_ = 0;
    float lastY_ = 0;
    float scrollResidual_ = 0;
    bool scrolled_ = false;
    bool moved_ = false;
    int64_t downTimeNs_ = 0;

    // 触控板虚拟指针（远端桌面坐标）。会话持有权威位置（含远端 SetPosition 归位），
    // 每次按下时从会话同步，这里只是手势期间的浮点工作副本
    float cursorX_ = 0;
    float cursorY_ = 0;
    float trackpadSensitivity_ = 1.6f;

    // 长按判定。与拖拽阈值分开：拖拽 14px 就触发，而按住整整 2 秒手指漂移远不止 14px，
    // 用同一个阈值的话长按几乎必然失败。这里单独给一个宽松的漂移上限
    bool holding_ = false;
    float holdX_ = 0;
    float holdY_ = 0;
    float holdDrift_ = 0;
    int64_t holdStartNs_ = 0;
    int holdLogged_ = 0;
};

// 外接鼠标事件（含悬停移动）
void HandleMouse(const OH_NativeXComponent_MouseEvent& event, RdpSession* session);

} // namespace hmrdp

#endif // HMRDP_INPUT_MAPPER_H
