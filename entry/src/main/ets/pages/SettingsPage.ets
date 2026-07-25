import { promptAction } from '@kit.ArkUI';
// focusControl 是 ArkUI 全局对象（common.d.ts 里声明），不能从 @kit.ArkUI 导入
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { DesktopHotkey, HotkeyPreset, HOTKEY_PRESETS, SettingsStore, defaultDesktopHotkey,
  hotkeyLabel, isModifierKey, MOD_CTRL, MOD_ALT, MOD_SHIFT } from '../model/SettingsStore';

const CAPTURE_ID = 'hmrdpHotkeyCapture';

@Component
export struct SettingsPage {
  @State hotkey: DesktopHotkey = defaultDesktopHotkey();
  /** true = 正在等用户按组合键 */
  @State capturing: boolean = false;
  /** 最近收到的按键，直接显示在界面上：录不进时能一眼看出是「没收到事件」还是「组合不合法」 */
  @State lastKeyInfo: string = '';
  /** 录入期间自己跟踪的修饰键按下态（MOD_* 位掩码） */
  private heldMods: number = 0;

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
  }

  aboutToAppear(): void {
    this.hotkey = SettingsStore.loadDesktopHotkey(this.ctx());
  }

  private persist(): void {
    SettingsStore.saveDesktopHotkey(this.ctx(), this.hotkey);
  }

  private apply(mods: number, keyCode: number): void {
    this.hotkey = { enabled: this.hotkey.enabled, mods: mods, keyCode: keyCode };
    this.capturing = false;
    this.persist();
    promptAction.showToast({ message: `已设为 ${hotkeyLabel(this.hotkey)}` });
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
    console.info(`HMRDP 热键录入：收到按键 code=${event.keyCode} type=${event.type}`);
    this.lastKeyInfo = `收到按键 code=${event.keyCode} type=${event.type}`;
    // 修饰键的按下/抬起都要跟，抬起事件不能提前被 KeyType.Down 过滤掉
    if (this.trackModifier(event)) {
      return;
    }
    if (event.type !== KeyType.Down) {
      return;
    }
    event.stopPropagation(); // 别让组合键继续冒泡（Backspace 等键会被上层当返回处理）
    const code = event.keyCode;
    if (isModifierKey(code)) {
      return; // Win/Meta 等也不能当触发键
    }
    if (code === KeyCode.KEYCODE_ESCAPE && this.modsOf(event) === 0) {
      this.capturing = false; // 空按 Esc = 放弃录入
      return;
    }
    const mods = this.modsOf(event);
    if (mods === 0) {
      promptAction.showToast({ message: '需要配合 Ctrl / Alt / Shift，请重新按一次' });
      return;
    }
    this.apply(mods, code);
  }

  private presetLabels(): SelectOption[] {
    return HOTKEY_PRESETS.map((p: HotkeyPreset): SelectOption =>
      ({ value: hotkeyLabel({ enabled: true, mods: p.mods, keyCode: p.keyCode }) }));
  }

  private presetIndex(): number {
    return HOTKEY_PRESETS.findIndex((p) => p.mods === this.hotkey.mods && p.keyCode === this.hotkey.keyCode);
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
                Text('返回鸿蒙桌面热键')
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
              // 捕获框：点一下用 focusControl 主动取焦点（鼠标点击不触发 focusOnTouch，
              // 只靠 focusable+focusOnTouch 在 PC 上录不到键），随后按下的组合键被录入
              Row() {
                Text(this.capturing ? '请按下组合键…' : hotkeyLabel(this.hotkey))
                  .fontSize(16)
                  .fontColor(this.capturing ? $r('sys.color.font_secondary') : $r('sys.color.font_primary'))
                Blank()
                Text(this.capturing ? '按 Esc 取消' : '点击后按键录入')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .width('100%')
              .padding(12)
              .borderRadius(10)
              .borderWidth(this.capturing ? 2 : 1)
              .borderColor(this.capturing ? '#1E7FD9' : $r('sys.color.comp_border_color'))
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .id(CAPTURE_ID)
              .focusable(true)
              .focusOnTouch(true)
              .defaultFocus(true) // 官方按键事件示例的用法：页面创建即持有焦点，否则收不到 onKeyEvent
              .onClick(() => {
                this.heldMods = 0; // 上次录入残留的按下态别带进来
                this.lastKeyInfo = '';
                this.capturing = true;
                const ok = focusControl.requestFocus(CAPTURE_ID);
                console.info(`HMRDP 热键录入：requestFocus=${ok}`);
                if (!ok) {
                  this.lastKeyInfo = '取焦点失败，请改用下面的「常用组合」';
                }
              })
              .onBlur(() => {
                this.capturing = false; // 焦点跑了就退出录入，别让提示一直挂着
              })
              .onKeyEvent((event: KeyEvent) => {
                this.onCaptureKey(event);
              })

              // 兜底路径：某些设备上 ArkUI 收不到带修饰键的组合（被系统先吃掉），直接选预设
              Row() {
                Text('常用组合')
                  .fontSize(14)
                Blank()
                Select(this.presetLabels())
                  .selected(this.presetIndex())
                  .value(this.presetIndex() >= 0 ? hotkeyLabel(this.hotkey) : '选择…')
                  .onSelect((index: number) => {
                    this.apply(HOTKEY_PRESETS[index].mods, HOTKEY_PRESETS[index].keyCode);
                  })
              }
              .width('100%')

              Text(`当前：${hotkeyLabel(this.hotkey)}（mods=${this.hotkey.mods} code=${this.hotkey.keyCode}）` +
                (this.lastKeyInfo.length > 0 ? `\n${this.lastKeyInfo}` : ''))
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'))
                .alignSelf(ItemAlign.Start)

              Button('恢复默认（Ctrl + Shift + Backspace）')
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .alignSelf(ItemAlign.Start)
                .onClick(() => {
                  const def = defaultDesktopHotkey();
                  this.apply(def.mods, def.keyCode);
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
        // 按键事件默认冒泡（官方 ts-universal-events-key 明确说明），所以在根容器再接一次：
        // 只要焦点落在本页任意子组件上（开关、下拉…）按键都能收到，不必非得让捕获框持有焦点
        .onKeyEvent((event: KeyEvent) => {
          this.onCaptureKey(event);
        })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('设置')
  }
}
