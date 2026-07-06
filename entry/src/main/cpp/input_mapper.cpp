#include "input_mapper.h"

#include <cmath>

#include <freerdp/input.h>
#include <ace/xcomponent/native_xcomponent_key_event.h>

#include "rdp_session.h"

namespace hmrdp {

namespace {

constexpr float kTapSlopPx = 14.0f;          // 超过则视为拖动
constexpr int64_t kTapTimeoutNs = 400000000; // 400ms 内抬起才算轻点
constexpr float kWheelStepPx = 32.0f;        // 每滑动 32px 发一档滚轮

uint32_t CountPressed(const OH_NativeXComponent_TouchEvent& event)
{
    uint32_t pressed = 0;
    for (uint32_t i = 0; i < event.numPoints && i < OH_NATIVE_XCOMPONENT_MAX_TOUCH_POINTS_NUMBER; i++) {
        if (event.touchPoints[i].isPressed)
            pressed++;
    }
    return pressed;
}

} // namespace

void TouchMapper::Reset()
{
    mode_ = Mode::Idle;
    scrollResidual_ = 0;
    scrolled_ = false;
}

void TouchMapper::OnTouch(const OH_NativeXComponent_TouchEvent& event, RdpSession* session)
{
    if (!session)
        return;

    const float x = event.x;
    const float y = event.y;
    const uint32_t pressed = CountPressed(event);

    switch (event.type) {
        case OH_NATIVEXCOMPONENT_DOWN:
            if (mode_ == Mode::Idle) {
                mode_ = Mode::Pending;
                downX_ = lastX_ = x;
                downY_ = lastY_ = y;
                downTimeNs_ = event.timeStamp;
                scrolled_ = false;
            } else if (mode_ == Mode::Pending && pressed >= 2) {
                // 第二根手指：进入双指模式（滚轮/右键）
                mode_ = Mode::TwoFinger;
                scrollResidual_ = 0;
                scrolled_ = false;
            } else if (mode_ == Mode::LeftDrag && pressed >= 2) {
                // 拖拽中落第二指：结束拖拽，转双指
                session->SendPointer(PTR_FLAGS_BUTTON1, lastX_, lastY_);
                mode_ = Mode::TwoFinger;
                scrollResidual_ = 0;
                scrolled_ = false;
            }
            break;

        case OH_NATIVEXCOMPONENT_MOVE:
            if (mode_ == Mode::Pending) {
                const float dx = x - downX_;
                const float dy = y - downY_;
                if (std::sqrt(dx * dx + dy * dy) > kTapSlopPx) {
                    // 转为拖拽：按下点先落左键
                    session->SendPointer(PTR_FLAGS_MOVE, downX_, downY_);
                    session->SendPointer(PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1, downX_, downY_);
                    session->SendPointer(PTR_FLAGS_MOVE, x, y);
                    mode_ = Mode::LeftDrag;
                }
            } else if (mode_ == Mode::LeftDrag) {
                session->SendPointer(PTR_FLAGS_MOVE, x, y);
            } else if (mode_ == Mode::TwoFinger) {
                const float dy = y - lastY_;
                scrollResidual_ += dy;
                while (std::fabs(scrollResidual_) >= kWheelStepPx) {
                    const int32_t direction = scrollResidual_ > 0 ? 1 : -1;
                    // 手指向下滑 = 内容上移 = 滚轮向下（负档）
                    session->SendWheel(direction > 0 ? -120 : 120, x, y);
                    scrollResidual_ -= direction * kWheelStepPx;
                    scrolled_ = true;
                }
            }
            lastX_ = x;
            lastY_ = y;
            break;

        case OH_NATIVEXCOMPONENT_UP:
            if (mode_ == Mode::Pending) {
                // 轻点 = 左键单击
                session->SendPointer(PTR_FLAGS_MOVE, downX_, downY_);
                session->SendPointer(PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1, downX_, downY_);
                session->SendPointer(PTR_FLAGS_BUTTON1, downX_, downY_);
                mode_ = Mode::Idle;
            } else if (mode_ == Mode::LeftDrag && pressed == 0) {
                session->SendPointer(PTR_FLAGS_MOVE, x, y);
                session->SendPointer(PTR_FLAGS_BUTTON1, x, y);
                mode_ = Mode::Idle;
            } else if (mode_ == Mode::TwoFinger && pressed == 0) {
                const int64_t elapsed = event.timeStamp - downTimeNs_;
                if (!scrolled_ && elapsed < kTapTimeoutNs) {
                    // 双指轻点 = 右键单击
                    session->SendPointer(PTR_FLAGS_MOVE, downX_, downY_);
                    session->SendPointer(PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON2, downX_, downY_);
                    session->SendPointer(PTR_FLAGS_BUTTON2, downX_, downY_);
                }
                mode_ = Mode::Idle;
            }
            break;

        case OH_NATIVEXCOMPONENT_CANCEL:
        default:
            if (mode_ == Mode::LeftDrag)
                session->SendPointer(PTR_FLAGS_BUTTON1, lastX_, lastY_);
            Reset();
            break;
    }
}

void HandleMouse(const OH_NativeXComponent_MouseEvent& event, RdpSession* session)
{
    if (!session)
        return;

    uint16_t button = 0;
    switch (event.button) {
        case OH_NATIVEXCOMPONENT_LEFT_BUTTON:
            button = PTR_FLAGS_BUTTON1;
            break;
        case OH_NATIVEXCOMPONENT_RIGHT_BUTTON:
            button = PTR_FLAGS_BUTTON2;
            break;
        case OH_NATIVEXCOMPONENT_MIDDLE_BUTTON:
            button = PTR_FLAGS_BUTTON3;
            break;
        default:
            button = 0;
            break;
    }

    switch (event.action) {
        case OH_NATIVEXCOMPONENT_MOUSE_PRESS:
            if (button)
                session->SendPointer(PTR_FLAGS_DOWN | button, event.x, event.y);
            break;
        case OH_NATIVEXCOMPONENT_MOUSE_RELEASE:
            if (button)
                session->SendPointer(button, event.x, event.y);
            break;
        case OH_NATIVEXCOMPONENT_MOUSE_MOVE:
            session->SendPointer(PTR_FLAGS_MOVE, event.x, event.y);
            break;
        default:
            break;
    }
}

bool OhosKeyToRdpScancode(uint32_t key, uint16_t& scancode, bool& extended)
{
    extended = false;

    // 字母 A-Z (2017-2042)
    if (key >= KEY_A && key <= KEY_Z) {
        static const uint16_t kLetters[26] = {
            0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, // A-J
            0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, // K-T
            0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C                          // U-Z
        };
        scancode = kLetters[key - KEY_A];
        return true;
    }
    // 主键盘数字 0-9 (2000-2009)
    if (key >= KEY_0 && key <= KEY_9) {
        scancode = (key == KEY_0) ? 0x0B : static_cast<uint16_t>(0x02 + (key - KEY_1));
        return true;
    }
    // F1-F12 (2090-2101)
    if (key >= KEY_F1 && key <= KEY_F12) {
        const uint32_t index = key - KEY_F1;
        scancode = index < 10 ? static_cast<uint16_t>(0x3B + index)
                              : static_cast<uint16_t>(0x57 + (index - 10));
        return true;
    }
    // 小键盘数字 (2103-2112)：0,1..9 -> 0x52,0x4F,0x50,0x51,0x4B,0x4C,0x4D,0x47,0x48,0x49
    if (key >= KEY_NUMPAD_0 && key <= KEY_NUMPAD_9) {
        static const uint16_t kNumpad[10] = { 0x52, 0x4F, 0x50, 0x51, 0x4B,
                                              0x4C, 0x4D, 0x47, 0x48, 0x49 };
        scancode = kNumpad[key - KEY_NUMPAD_0];
        return true;
    }

    switch (key) {
        case KEY_DPAD_UP:      scancode = 0x48; extended = true; return true;
        case KEY_DPAD_DOWN:    scancode = 0x50; extended = true; return true;
        case KEY_DPAD_LEFT:    scancode = 0x4B; extended = true; return true;
        case KEY_DPAD_RIGHT:   scancode = 0x4D; extended = true; return true;
        case KEY_COMMA:        scancode = 0x33; return true;
        case KEY_PERIOD:       scancode = 0x34; return true;
        case KEY_ALT_LEFT:     scancode = 0x38; return true;
        case KEY_ALT_RIGHT:    scancode = 0x38; extended = true; return true;
        case KEY_SHIFT_LEFT:   scancode = 0x2A; return true;
        case KEY_SHIFT_RIGHT:  scancode = 0x36; return true;
        case KEY_TAB:          scancode = 0x0F; return true;
        case KEY_SPACE:        scancode = 0x39; return true;
        case KEY_ENTER:        scancode = 0x1C; return true;
        case KEY_DEL:          scancode = 0x0E; return true; // Backspace
        case KEY_GRAVE:        scancode = 0x29; return true;
        case KEY_MINUS:        scancode = 0x0C; return true;
        case KEY_EQUALS:       scancode = 0x0D; return true;
        case KEY_LEFT_BRACKET: scancode = 0x1A; return true;
        case KEY_RIGHT_BRACKET: scancode = 0x1B; return true;
        case KEY_BACKSLASH:    scancode = 0x2B; return true;
        case KEY_SEMICOLON:    scancode = 0x27; return true;
        case KEY_APOSTROPHE:   scancode = 0x28; return true;
        case KEY_SLASH:        scancode = 0x35; return true;
        case KEY_PAGE_UP:      scancode = 0x49; extended = true; return true;
        case KEY_PAGE_DOWN:    scancode = 0x51; extended = true; return true;
        case KEY_ESCAPE:       scancode = 0x01; return true;
        case KEY_FORWARD_DEL:  scancode = 0x53; extended = true; return true; // Delete
        case KEY_CTRL_LEFT:    scancode = 0x1D; return true;
        case KEY_CTRL_RIGHT:   scancode = 0x1D; extended = true; return true;
        case KEY_CAPS_LOCK:    scancode = 0x3A; return true;
        case KEY_META_LEFT:    scancode = 0x5B; extended = true; return true; // Win 键
        case KEY_SYSRQ:        scancode = 0x37; extended = true; return true; // PrintScreen
        case KEY_MOVE_HOME:    scancode = 0x47; extended = true; return true;
        case KEY_MOVE_END:     scancode = 0x4F; extended = true; return true;
        case KEY_INSERT:       scancode = 0x52; extended = true; return true;
        case KEY_NUM_LOCK:     scancode = 0x45; return true;
        case KEY_NUMPAD_DIVIDE:   scancode = 0x35; extended = true; return true;
        case KEY_NUMPAD_MULTIPLY: scancode = 0x37; return true;
        case KEY_NUMPAD_SUBTRACT: scancode = 0x4A; return true;
        case KEY_NUMPAD_ADD:      scancode = 0x4E; return true;
        case KEY_NUMPAD_DOT:      scancode = 0x53; return true;
        case KEY_NUMPAD_ENTER:    scancode = 0x1C; extended = true; return true;
        default:
            return false;
    }
}

} // namespace hmrdp
