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
    bool IsTrackpad() const { return trackpad_; }
    // false = 直接触摸模式，true = 触控板（相对指针）模式
    void SetTrackpadMode(bool trackpad);

private:
    enum class Mode : uint8_t { Idle, Pending, LeftDrag, TwoFinger };

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
};

// 外接鼠标事件（含悬停移动）
void HandleMouse(const OH_NativeXComponent_MouseEvent& event, RdpSession* session);

} // namespace hmrdp

#endif // HMRDP_INPUT_MAPPER_H
