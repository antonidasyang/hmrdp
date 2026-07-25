import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { EscapeHotkey, SettingsStore, defaultEscapeHotkey, hotkeyLabel, isModifierKey,
  MOD_CTRL, MOD_ALT, MOD_SHIFT } from '../model/SettingsStore';

@Component
export struct SettingsPage {
  @State hotkey: EscapeHotkey = defaultEscapeHotkey();
  /** true = 正在等用户按组合键 */
  @State capturing: boolean = false;
  /** 录入期间自己跟踪的修饰键按下态（MOD_* 位掩码） */
  private heldMods: number = 0;

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
  }

  aboutToAppear(): void {
    this.hotkey = SettingsStore.loadEscapeHotkey(this.ctx());
  }

  private persist(): void {
    SettingsStore.saveEscapeHotkey(this.ctx(), this.hotkey);
  }

  /** 查询单个修饰键是否按下。getModifierKeyState 是可选 API（API 12+），且 SDK 注释里
   *  'ctrl' 与 'Ctrl' 两种写法都出现过，两种都试一次，别在某个版本上恒返回 false */
  private modDown(event: KeyEvent, name: string): boolean {
    const spellings: string[] = [name.toLowerCase(), name];
    for (const spelling of spellings) {
      try {
        if (event.getModifierKeyState !== undefined && event.getModifierKeyState([spelling])) {
          return true;
        }
      } catch (e) {
        // 该写法不被支持，试下一种
      }
    }
    return false;
  }

  private modsOf(event: KeyEvent): number {
    let mods = 0;
    if (this.modDown(event, 'Ctrl')) {
      mods |= MOD_CTRL;
    }
    if (this.modDown(event, 'Alt')) {
      mods |= MOD_ALT;
    }
    if (this.modDown(event, 'Shift')) {
      mods |= MOD_SHIFT;
    }
    return mods | this.heldMods; // 并上自跟踪结果：getModifierKeyState 整个不可用时靠它
  }

  /** 记录修饰键按下/抬起。返回 true = 这个键本身就是修饰键，不能当触发键 */
  private trackModifier(event: KeyEvent): boolean {
    const code = event.keyCode;
    let bit = 0;
    if (code === KeyCode.KEYCODE_CTRL_LEFT || code === KeyCode.KEYCODE_CTRL_RIGHT) {
      bit = MOD_CTRL;
    } else if (code === KeyCode.KEYCODE_ALT_LEFT || code === KeyCode.KEYCODE_ALT_RIGHT) {
      bit = MOD_ALT;
    } else if (code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT) {
      bit = MOD_SHIFT;
    }
    if (bit === 0) {
      return false;
    }
    if (event.type === KeyType.Down) {
      this.heldMods |= bit;
    } else {
      this.heldMods &= ~bit;
    }
    return true;
  }

  private onCaptureKey(event: KeyEvent): void {
    if (!this.capturing) {
      return;
    }
    // 修饰键的按下/抬起都要跟，抬起事件不能提前被 KeyType.Down 过滤掉
    if (this.trackModifier(event)) {
      return;
    }
    if (event.type !== KeyType.Down) {
      return;
    }
    event.stopPropagation(); // 别让组合键继续冒泡触发页面上的其它响应
    const code = event.keyCode;
    if (isModifierKey(code)) {
      return; // Win/Meta 等也不能当触发键
    }
    const mods = this.modsOf(event);
    if (mods === 0) {
      promptAction.showToast({ message: '需要配合 Ctrl / Alt / Shift，请重新按一次' });
      return;
    }
    this.hotkey = { enabled: this.hotkey.enabled, mods: mods, keyCode: code };
    this.capturing = false;
    this.persist();
    promptAction.showToast({ message: `已设为 ${hotkeyLabel(this.hotkey)}` });
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('sys.color.font_secondary'))
      .alignSelf(ItemAlign.Start)
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          this.sectionTitle('全屏会话')

          Column({ space: 12 }) {
            Row() {
              Column({ space: 2 }) {
                Text('逃逸热键')
                  .fontSize(15)
                Text('全屏会话中按下即最小化回桌面，连接不断')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.hotkey.enabled })
                .onChange((on: boolean) => {
                  this.hotkey = { enabled: on, mods: this.hotkey.mods, keyCode: this.hotkey.keyCode };
                  this.capturing = false;
                  this.persist();
                })
            }
            .width('100%')

            if (this.hotkey.enabled) {
              // 捕获框：点一下取得焦点，随后按下的组合键被录入（主窗口不在键盘拦截态，按键正常送到 ArkUI）
              Row() {
                Text(this.capturing ? '请按下组合键…' : hotkeyLabel(this.hotkey))
                  .fontSize(16)
                  .fontColor(this.capturing ? $r('sys.color.font_secondary') : $r('sys.color.font_primary'))
                Blank()
                Text(this.capturing ? '按 Esc 取消' : '点击修改')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .width('100%')
              .padding(12)
              .borderRadius(10)
              .borderWidth(1)
              .borderColor(this.capturing ? '#1E7FD9' : $r('sys.color.comp_background_tertiary'))
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .focusable(true)
              .focusOnTouch(true)
              .onClick(() => {
                this.heldMods = 0; // 上次录入残留的按下态别带进来
                this.capturing = true;
              })
              .onKeyEvent((event: KeyEvent) => {
                // Esc 单独处理：它也可能是用户想录的键，但没带修饰键时按取消更符合直觉
                if (this.capturing && event.type === KeyType.Down &&
                  event.keyCode === KeyCode.KEYCODE_ESCAPE && this.modsOf(event) === 0) {
                  this.capturing = false;
                  return;
                }
                this.onCaptureKey(event);
              })

              Button('恢复默认（Ctrl + Shift + Backspace）')
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .alignSelf(ItemAlign.Start)
                .onClick(() => {
                  const def = defaultEscapeHotkey();
                  this.hotkey = { enabled: this.hotkey.enabled, mods: def.mods, keyCode: def.keyCode };
                  this.capturing = false;
                  this.persist();
                })

              Text('仅 PC/2in1 的独立全屏会话生效。这个组合键会被本地吃掉、不再发给远端电脑，' +
                '所以别选远端常用的组合。被鸿蒙自己占用的组合（含 Win 键等）录不进来。')
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'))
                .alignSelf(ItemAlign.Start)
            }
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          Text('会话工具条右下角的「回桌面」按钮和这个热键等效，鼠标可用时可以直接点它。')
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
            .alignSelf(ItemAlign.Start)
        }
        .padding(16)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('设置')
  }
}
