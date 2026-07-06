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

private:
    enum class Mode : uint8_t { Idle, Pending, LeftDrag, TwoFinger };

    Mode mode_ = Mode::Idle;
    float downX_ = 0;
    float downY_ = 0;
    float lastX_ = 0;
    float lastY_ = 0;
    float scrollResidual_ = 0;
    bool scrolled_ = false;
    int64_t downTimeNs_ = 0;
};

// 外接鼠标事件（含悬停移动）
void HandleMouse(const OH_NativeXComponent_MouseEvent& event, RdpSession* session);

} // namespace hmrdp

#endif // HMRDP_INPUT_MAPPER_H
