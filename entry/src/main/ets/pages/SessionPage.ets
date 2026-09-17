import { display, promptAction, window } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { common } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { resolveSharePath, SHARE_TARGETS } from '../model/ShareFolders';
import hmrdp from 'libhmrdp.so';
import { SessionParams } from '../model/SessionParams';
import { CertStore } from '../model/CertStore';
import { PCStore } from '../model/PCStore';
import { SoftKeyboard, ImeKeyBar, SOFT_KB_H, IME_BAR_H, IME_HANDLE_H, ACT_IME, ACT_ABC,
  ACT_FOLD, PAN_START, PAN_UPDATE } from '../components/SoftKeyboard';
import { isPcDevice, isLargeScreen, defaultScalePercent } from '../model/DeviceKit';
import { DesktopHotkey, SettingsStore, defaultDesktopHotkey, hotkeyLabel,
  MOD_CTRL, MOD_ALT, MOD_SHIFT } from '../model/SettingsStore';
import { inputConsumer, KeyCode } from '@kit.InputKit';
import { SessionAliveResponder } from '../model/SessionProbe';

const SC_BACKSPACE = 0x0E;
const SC_ENTER = 0x1C;

/** 修饰键：粘滞式，点亮后随下一个键一起发出再自动松开 */
interface ModKey {
  label: string;
  code: number;
  ext: boolean;
}

/** stickyMods 里 Shift 的位（MOD_KEYS 下标 2） */
const MOD_SHIFT_BIT = 4;

const MOD_KEYS: ModKey[] = [
  { label: 'Ctrl', code: 0x1D, ext: false },
  { label: 'Alt', code: 0x38, ext: false },
  { label: 'Shift', code: 0x2A, ext: false },
  { label: 'Win', code: 0x5B, ext: true }
];

/** 字母 A-Z 的扫描码，用于把软键盘打出的字符转成带修饰键的组合（Ctrl+C 等）。
 *  与原生 OhosKeyToRdpScancode 的 kLetters 同表。 */
const SC_LETTERS: number[] = [
  0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, // A-J
  0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, // K-T
  0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C                          // U-Z
];
/** 数字 0-9 的扫描码 */
const SC_DIGITS: number[] = [0x0B, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A];

// libhmrdp.so 的 CertRequest 本地镜像
interface HmCertRequest {
  host: string;
  port: number;
  commonName: string;
  subject: string;
  issuer: string;
  fingerprint: string;
  changed: boolean;
}

/** FreeRDP 错误串 -> 用户可读提示 */
function friendlyError(message: string): string {
  if (message.length === 0) {
    return '连接已断开';
  }
  if (message.includes('LOGON_FAILURE') || message.includes('AUTHENTICATION_FAILED')) {
    return '登录失败：用户名或密码错误';
  }
  if (message.includes('ACCOUNT_LOCKED_OUT')) {
    return '登录失败：账户已被锁定';
  }
  if (message.includes('ACCOUNT_DISABLED')) {
    return '登录失败：账户已被禁用';
  }
  if (message.includes('PASSWORD_EXPIRED') || message.includes('PASSWORD_MUST_CHANGE')) {
    return '登录失败：密码已过期，请先在 Windows 上修改密码';
  }
  if (message.includes('CONNECT_CANCELLED')) {
    return '连接已取消';
  }
  if (message.includes('CONNECT_TRANSPORT_FAILED') || message.includes('CONNECT_FAILED')) {
    return '无法连接到远程电脑，请检查地址、网络，以及远程桌面是否已开启';
  }
  if (message.includes('DNS_NAME_NOT_FOUND') || message.includes('DNS_ERROR')) {
    return '找不到这台电脑：主机名无法解析';
  }
  if (message.includes('TLS_CONNECT_FAILED') || message.includes('SECURITY_NEGO')) {
    return '安全连接建立失败';
  }
  if (message.includes('DISCONNECT_BY_USER') || message.includes('LOGOFF_BY_USER')) {
    return '已在远程电脑上注销';
  }
  if (message.includes('RPC_INITIATED_DISCONNECT') || message.includes('DISCONNECT')) {
    return '远程电脑断开了连接（可能被其他用户登录顶替）';
  }
  return `连接已断开：${message}`;
}

// libhmrdp.so 的 ConnectConfig 本地镜像（.so 具名类型导入在部分 SDK 版本不稳定）
interface HmConnectConfig {
  host: string;
  port: number;
  username: string;
  password: string;
  domain: string;
  width: number;
  height: number;
  scale: number;
  dynamic: number;
  drives: HmDriveEntry[];
}

interface HmDriveEntry {
  name: string;
  path: string;
}

const STATE_CONNECTING = 0;
const STATE_CONNECTED = 1;
const STATE_DISCONNECTED = 2;

@Component
struct ToolButton {
  // 用 @Component + @Prop 而非 @Builder：ArkUI V1 中 @Builder 值参不响应状态变化，
  // 会导致按钮图标/文字/激活色在状态切换后不刷新。@Prop 单向同步是响应式的。
  @Prop symbol: Resource = $r('sys.symbol.xmark');
  @Prop label: string = '';
  @Prop active: boolean = false;
  /** 线条太细的符号（如 circle）加粗后在深色工具条上更清晰。
   *  用数值字重：HMSymbolVF 的 wght 轴到 900，900 即最粗，比 FontWeight.Bold 更实 */
  @Prop bold: boolean = false;
  /** 符号字号，默认与其余图标一致。circle 是纯圆、视觉面积偏大，可单独调小。
   *  不能叫 size：与 CustomComponent 的通用属性重名，编译期报 not assignable */
  @Prop iconSize: number = 22;
  action: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      SymbolGlyph(this.symbol)
        .fontSize(this.iconSize)
        .fontWeight(this.bold ? 900 : 400)
        .fontColor([this.active ? '#4DA3FF' : Color.White])
      Text(this.label)
        .fontSize(10)
        .fontColor(this.active ? '#4DA3FF' : Color.White)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .onClick(() => { this.action(); })
  }
}

@Component
export struct SessionPage {
  @State statusText: string = '正在连接…';
  @State connected: boolean = false;
  @State keyboardShown: boolean = false;
  @State errorText: string = '';
  @State toolbarExpanded: boolean = true;
  @State trackpadMode: boolean = false;
  @State isPc: boolean = false;
  @State fullscreen: boolean = false;
  // 多显示器（PC 外接屏/投屏）：>1 块屏时工具条出现「屏幕」菜单，可把会话窗口搬过去
  @State displays: display.Display[] = [];
  @State curDisplayId: number = -1;
  private displayChangeCb: (id: number) => void = (_id: number) => {
    this.refreshDisplays();
  };
  // 视图缩放/平移（作用于 XComponent 显示，不改变远端分辨率）
  @State viewScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private baseScale: number = 1;
  private baseOffsetX: number = 0;
  private baseOffsetY: number = 0;
  // 软键盘盖住画面下半部分时，允许把画面整体上推（最多推到键盘顶边），
  // 像 Windows App 那样拖一下就能看到被键盘挡住的内容。kbHeight 为 vp，0 = 键盘未弹出
  @State kbHeight: number = 0;
  @State kbShift: number = 0;
  /** 粘滞按下的修饰键（位掩码，见 MOD_KEYS 下标）；紧凑键盘与导航面板共用同一套 */
  @State stickyMods: number = 0;
  /** 会话自带的紧凑键盘（自绘）是否显示。打中文时让位给系统输入法，
   *  改由功能键横条（ImeKeyBar）顶上 */
  @State softKb: boolean = false;
  /** 打中文时的功能键横条是否折叠（折叠后只剩一个小把手，屏幕上只有系统键盘） */
  @State imeBarFolded: boolean = false;
  private baseKbShift: number = 0;
  // 正在上推画面的手势用了几根手指（0 = 没有）。PanGesture 的 fingers 是「至少几指」，
  // 双指拖动会把单指 Pan 一起触发，靠这个只认一个手势的回调，免得两边互相抢
  private kbPanFingers: number = 0;
  private kbWin: window.Window | undefined = undefined;
  private kbHeightCb: (h: number) => void = (h: number) => {
    this.onKeyboardHeight(h);
  };
  private viewW: number = 0;
  private viewH: number = 0;
  // 滚轮：不足一档的余量（单位＝档），以及首个事件学到的“一档轴值”
  private wheelAccum: number = 0;
  private wheelUnit: number = 0;
  private wheelLogged: number = 0;
  private pathStack: NavPathStack | null = null;
  private params: SessionParams = new SessionParams();
  private closing: boolean = false;
  private imeAttached: boolean = false;
  // 剪贴板同步（防回环：两端最近一次同步的文本）
  private clipLast: string = '';
  private clipLastImage: number = 0; // 本地图片去重（PNG 字节长度）
  private clipListening: boolean = false;
  private clipSelfWrite: boolean = false; // 刚由远端写入本地，跳过下一次读取回声
  private clipUpdateHandler: () => void = () => {
    this.onLocalClipboardChanged();
  };
  // 物理键盘拦截（受限权限；失焦即释放，避免键盘被卡住）
  private keyWin: window.Window | undefined = undefined;
  private winEventCb: (t: window.WindowEventType) => void = (t: window.WindowEventType) => {
    this.onWindowEvent(t);
  };
  /** 物理键盘拦截是否真的生效（受限权限未授予时为 false）。决定热键走哪条路：
   *  拦截生效 = 事件不再下发，只有原生 OnInterceptedKey 能拿到；
   *  拦截未生效 = 事件正常下发，inputConsumer 的组合键订阅才会触发。 */
  private keyIntercepting: boolean = false;
  /** 应答主窗口的「还有会话在跑吗」探测：主窗口关闭前据此弹确认框 */
  private aliveResponder: SessionAliveResponder = new SessionAliveResponder();
  // 「返回鸿蒙桌面」热键：已向系统注册的组合（inputConsumer），用于 off 时精确注销
  private hotkeyRegs: inputConsumer.HotkeyOptions[] = [];
  private hotkeyCb: (options: inputConsumer.HotkeyOptions) => void =
    (options: inputConsumer.HotkeyOptions) => {
      console.info(`HMRDP 返回桌面热键：系统回调命中 finalKey=${options.finalKey}`);
      this.minimizeWindow();
    };

  private clampOffsets(): void {
    // 缩放后允许平移的范围 = 溢出的一半
    const maxX = Math.max(0, (this.viewW * this.viewScale - this.viewW) / 2);
    const maxY = Math.max(0, (this.viewH * this.viewScale - this.viewH) / 2);
    this.offsetX = Math.min(maxX, Math.max(-maxX, this.offsetX));
    this.offsetY = Math.min(maxY, Math.max(-maxY, this.offsetY));
  }

  private resetZoom(): void {
    this.viewScale = 1;
    this.offsetX = 0;
    this.offsetY = 0;
  }

  aboutToAppear(): void {
    this.isPc = isPcDevice();
    if (this.isPc) {
      hmrdp.setTouchEnabled(false); // PC 有物理键鼠，关掉 TouchMapper 避免和鼠标回调产生双击
      this.refreshDisplays();
      try {
        display.on('add', this.displayChangeCb); // 外接屏插拔时刷新「屏幕」菜单
        display.on('remove', this.displayChangeCb);
      } catch (e) {
        // 接口不可用时降级：菜单只按启动时的显示器列表
      }
    }
  }

  // ---- 多显示器：会话窗口放到哪块屏（外接显示器/投屏场景）----

  private refreshDisplays(): void {
    display.getAllDisplays().then((list: display.Display[]) => {
      this.displays = list;
    }).catch((e: BusinessError) => {
      console.warn(`HMRDP 查询显示器列表失败: code=${e.code}`);
    });
    window.getLastWindow(this.ctx()).then((win: window.Window) => {
      const id = win.getWindowProperties().displayId;
      this.curDisplayId = id !== undefined ? id : -1;
    }).catch(() => {
    });
  }

  private displayMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const d of this.displays) {
      const name = d.name !== undefined && d.name.length > 0 ? d.name : `显示器 ${d.id}`;
      const label = `${name}（${d.width}×${d.height}）`;
      items.push({
        value: d.id === this.curDisplayId ? `${label} · 当前` : label,
        action: () => {
          this.moveToDisplay(d.id, name);
        }
      });
    }
    return items;
  }

  /** 把会话全屏窗口搬到指定显示器。maximize 态的窗口不能直接移动（1300010：仅浮动态可移），
   *  所以先 recover 回浮动态 → moveWindowToGlobal 落到目标屏 → 再 maximize 回沉浸全屏。
   *  移动后 surface 尺寸变化会经动态分辨率（disp 通道）自动匹配新屏幕。 */
  private async moveToDisplay(displayId: number, name: string): Promise<void> {
    try {
      const win = await window.getLastWindow(this.ctx());
      if (win.getWindowProperties().displayId === displayId) {
        return; // 已在目标屏
      }
      try {
        await win.recover(); // 已是浮动态或形态不支持时继续尝试移动
      } catch (e) {
      }
      const conf: window.MoveConfiguration = { displayId: displayId };
      await win.moveWindowToGlobal(0, 0, conf);
      try {
        await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
      } catch (e) {
        win.maximize().catch(() => {
        }); // 不支持沉浸入参的设备退回普通最大化
      }
      this.curDisplayId = displayId;
      promptAction.showToast({ message: `已移至${name}` });
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HMRDP 移动到显示器失败: code=${err.code} msg=${err.message}`);
      promptAction.showToast({ message: '移动窗口失败，请重试' });
    }
  }

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
  }

  /** 全屏（仅手机/平板）：沉浸式隐藏系统栏。PC 会话窗口由 SessionAbility 统一最大化管理，
   *  页面不再直接操作窗口（避免 maximize/recover 冲突导致崩溃）。 */
  private async applyFullscreen(on: boolean): Promise<void> {
    if (this.isPc) {
      return;
    }
    try {
      const win = await window.getLastWindow(this.ctx());
      await win.setWindowLayoutFullScreen(on);
      const bars: Array<'status' | 'navigation'> = on ? [] : ['status', 'navigation'];
      await win.setWindowSystemBarEnable(bars);
      this.fullscreen = on;
    } catch (e) {
      // 部分设备形态不支持全屏，忽略
    }
  }

  /** 会话一律横屏（远端桌面是横向的，竖屏没法用）；退出时按形态还原——
   *  平板与折叠屏内屏（大屏）继续横屏，手机与折叠屏外屏回竖屏。
   *  PC/2in1 是窗口化形态，朝向无意义也不该动。 */
  private async applyOrientation(landscape: boolean): Promise<void> {
    if (this.isPc) {
      return;
    }
    // 横屏用 AUTO_ROTATION_LANDSCAPE：左右两个横向都允许，用户怎么拿都行
    const target = (landscape || isLargeScreen()) ? window.Orientation.AUTO_ROTATION_LANDSCAPE
                                                  : window.Orientation.PORTRAIT;
    try {
      const win = await window.getLastWindow(this.ctx());
      await win.setPreferredOrientation(target);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HMRDP 设置屏幕朝向失败: code=${err.code}`);
    }
  }

  /** 最小化会话窗口回鸿蒙桌面：RDP 连接保持（surface 销毁只 DetachWindow），从任务栏点回来继续。
   *  PC 全屏会话没有系统标题栏/Dock 悬浮出口（见 SessionAbility.enterImmersive），这是主要退路。
   *  窗口 HIDDEN 时 onWindowEvent 会自动放开键盘拦截，切回来重新抢占。 */
  private async minimizeWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.ctx());
      await win.minimize();
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HMRDP 最小化会话窗口失败: code=${err.code}`);
      promptAction.showToast({ message: '当前设备不支持最小化' });
    }
  }

  /** 向远端发送一组组合键（依次按下、逆序抬起）。keys: [scancode, extended(0/1)][] */
  private sendCombo(keys: number[][]): void {
    for (let i = 0; i < keys.length; i++) {
      hmrdp.sendScancode(keys[i][0], keys[i][1] === 1, true);
    }
    for (let i = keys.length - 1; i >= 0; i--) {
      hmrdp.sendScancode(keys[i][0], keys[i][1] === 1, false);
    }
  }

  /** 系统/快捷键菜单：由 App 生成扫描码发给远端 Windows（绕过鸿蒙对 Win 键等的拦截） */
  private systemKeysMenu(): MenuElement[] {
    return [
      { value: 'Win（开始菜单）', action: () => this.sendCombo([[0x5B, 1]]) },
      { value: 'Win + D（显示桌面）', action: () => this.sendCombo([[0x5B, 1], [0x20, 0]]) },
      { value: 'Win + E（资源管理器）', action: () => this.sendCombo([[0x5B, 1], [0x12, 0]]) },
      { value: 'Win + R（运行）', action: () => this.sendCombo([[0x5B, 1], [0x13, 0]]) },
      { value: 'Win + L（锁屏）', action: () => this.sendCombo([[0x5B, 1], [0x26, 0]]) },
      { value: 'Ctrl + Alt + Del', action: () => this.sendCombo([[0x1D, 0], [0x38, 0], [0x53, 1]]) },
      { value: 'Alt + Tab（切换窗口）', action: () => this.sendCombo([[0x38, 0], [0x0F, 0]]) },
      { value: 'Alt + F4（关闭窗口）', action: () => this.sendCombo([[0x38, 0], [0x3E, 0]]) },
      { value: 'Esc', action: () => this.sendCombo([[0x01, 0]]) }
    ] as MenuElement[];
  }

  private toggleFullscreen(): void {
    this.applyFullscreen(!this.fullscreen);
  }

  // ---- 物理键盘全局拦截（把含 Win 的全键盘转发远端；需受限权限，未授权自动降级）----

  private async setupKeyInterception(): Promise<void> {
    try {
      this.keyWin = await window.getLastWindow(this.ctx());
      this.keyWin.on('windowEvent', this.winEventCb);
    } catch (e) {
    }
    // 返回值 = 是否真的处于拦截态。未授予 INTERCEPT_INPUT_EVENT 时恒 false，
    // 此时 OnInterceptedKey 一次都不会被调用，热键只能靠 inputConsumer 那条路。
    this.keyIntercepting = hmrdp.setKeyInterception(true);
    console.info(`HMRDP 键盘拦截态=${this.keyIntercepting}`);
    this.armDesktopHotkey(true);
  }

  /** 下发「返回鸿蒙桌面」热键（设置页可配，默认 Ctrl+Alt+Backspace）。命中后原生不转发该键，
   *  回调这里最小化回桌面。连接成功时下发，窗口重新聚焦时重读（改完设置无需重连）。 */
  /** notify=true 时用 toast 报一次结果（连接成功那次）；窗口重新聚焦的重复武装不打扰用户 */
  private armDesktopHotkey(notify: boolean): void {
    let hk: DesktopHotkey;
    try {
      hk = SettingsStore.loadDesktopHotkey(this.ctx());
    } catch (e) {
      hk = defaultDesktopHotkey(); // 读设置失败也要有热键可用，别整个功能哑掉
    }
    if (!hk.enabled || hk.mods === 0 || hk.keyCode === 0) {
      this.unregisterSystemHotkey();
      try {
        hmrdp.setDesktopHotkey(0, 0);
      } catch (e) {
      }
      console.info('HMRDP 返回桌面热键：已关闭');
      return;
    }
    // 路线一：拦截态下按键不再下发给任何人（源码 EventInterceptorHandler::HandleKeyEvent
    // 命中即 return，不调 nextHandler_），只有我们自己的拦截回调能拿到 → 原生匹配。
    let nativeOk = false;
    try {
      hmrdp.setDesktopHotkey(hk.mods, hk.keyCode, () => {
        console.info('HMRDP 返回桌面热键：原生回调命中');
        this.minimizeWindow();
      });
      nativeOk = true;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HMRDP 返回桌面热键：下发原生失败 code=${err.code} ${err.message}`);
    }
    // 路线二：拦截未生效（无受限权限）时事件正常下发，走系统组合键订阅
    const sysCount = this.registerSystemHotkey(hk);
    const label = hotkeyLabel(hk);
    console.info(`HMRDP 返回桌面热键：${label} 原生=${nativeOk} 系统订阅=${sysCount} 拦截态=${this.keyIntercepting}`);
    // 直接显示给用户：没有 hdc 也能看出热键到底武装上没有、走的哪条路
    if (notify) {
      promptAction.showToast({
        message: `返回桌面热键 ${label}（${this.keyIntercepting ? '拦截态·原生' : `系统订阅 ${sysCount} 组`}）`,
        duration: 2500
      });
    }
  }

  /** 修饰键位掩码 -> 该修饰键的左右键码。inputConsumer 的 preKeys 认具体键码，
   *  左右两个都要各注册一遍，否则只有其中一侧生效。 */
  private modKeyCodes(mods: number, bit: number, left: number, right: number): number[] {
    return (mods & bit) !== 0 ? [left, right] : [];
  }

  /** 用 inputConsumer 向系统注册组合键（API 14，无需权限）。仅在键盘拦截未生效时才可能触发：
   *  拦截生效时事件在 EventInterceptorHandler 就被吃掉，根本到不了 EventSubscriberHandler。
   *  官方文档 preKeys 取值范围 [1,4]，但 SDK 注释写「最多两个修饰键」，按 2 个处理更稳。
   *  返回成功注册的组合数。 */
  private registerSystemHotkey(hk: DesktopHotkey): number {
    this.unregisterSystemHotkey();
    if (!hk.enabled || hk.mods === 0 || hk.keyCode === 0) {
      return 0;
    }
    const ctrls = this.modKeyCodes(hk.mods, MOD_CTRL, KeyCode.KEYCODE_CTRL_LEFT, KeyCode.KEYCODE_CTRL_RIGHT);
    const alts = this.modKeyCodes(hk.mods, MOD_ALT, KeyCode.KEYCODE_ALT_LEFT, KeyCode.KEYCODE_ALT_RIGHT);
    const shifts = this.modKeyCodes(hk.mods, MOD_SHIFT, KeyCode.KEYCODE_SHIFT_LEFT, KeyCode.KEYCODE_SHIFT_RIGHT);
    // 三个修饰键超出 inputConsumer 上限（preKeys 最多 2 个），交给原生路径
    const groups: number[][] = [ctrls, alts, shifts].filter((g) => g.length > 0);
    if (groups.length > 2) {
      console.info('HMRDP 返回桌面热键：3 个修饰键超出系统接口上限，仅走原生判定');
      return 0;
    }
    // 左右键的全部组合各注册一次
    const combos: number[][] = groups.length === 0 ? [[]] : groups[0].map((k): number[] => [k]);
    const expanded: number[][] = [];
    if (groups.length === 2) {
      for (const a of combos) {
        for (const b of groups[1]) {
          expanded.push([a[0], b]);
        }
      }
    }
    const finalCombos: number[][] = groups.length === 2 ? expanded : combos;
    for (const preKeys of finalCombos) {
      const options: inputConsumer.HotkeyOptions = {
        preKeys: preKeys,
        finalKey: hk.keyCode,
        isRepeat: false
      };
      try {
        inputConsumer.on('hotkeyChange', options, this.hotkeyCb);
        this.hotkeyRegs.push(options);
      } catch (e) {
        const err = e as BusinessError;
        // 4200002 = 该组合被系统占用，4200003 = 已被其它应用订阅
        console.warn(`HMRDP 返回桌面热键：系统注册失败 preKeys=${preKeys} code=${err.code} ${err.message}`);
      }
    }
    console.info(`HMRDP 返回桌面热键：系统注册 ${this.hotkeyRegs.length}/${finalCombos.length} 组 finalKey=${hk.keyCode}`);
    return this.hotkeyRegs.length;
  }

  private unregisterSystemHotkey(): void {
    for (const options of this.hotkeyRegs) {
      try {
        inputConsumer.off('hotkeyChange', options, this.hotkeyCb);
      } catch (e) {
        // 未注册成功的组合忽略
      }
    }
    this.hotkeyRegs = [];
  }

  private teardownKeyInterception(): void {
    hmrdp.setKeyInterception(false);
    this.unregisterSystemHotkey();
    try {
      hmrdp.setDesktopHotkey(0, 0);
    } catch (e) {
      // 旧 .so 无该导出，忽略
    }
    if (this.keyWin) {
      try {
        this.keyWin.off('windowEvent', this.winEventCb);
      } catch (e) {
      }
      this.keyWin = undefined;
    }
  }

  private onWindowEvent(type: window.WindowEventType): void {
    // 失焦/隐藏即释放键盘（用鼠标点其它窗口即可脱离）；重新聚焦且仍连接则恢复拦截
    if (type === window.WindowEventType.WINDOW_INACTIVE || type === window.WindowEventType.WINDOW_HIDDEN) {
      hmrdp.setKeyInterception(false);
    } else if (type === window.WindowEventType.WINDOW_ACTIVE && this.connected) {
      this.keyIntercepting = hmrdp.setKeyInterception(true);
      this.armDesktopHotkey(false); // 顺带重读设置：改完热键切回会话窗口即生效，不必重连
      this.refreshDisplays(); // 顺带刷新窗口当前所在屏，「屏幕」菜单的「当前」标注才准
    }
  }

  /** 会话内切换触摸模式后记到这台电脑上，下次连它自动沿用。
   *  只改 trackpad 单字段（PCStore.setTrackpad），不整对象回写——会话持有的是进入时的快照，
   *  整条写回会把期间在编辑页改过的分辨率/账号等覆盖掉。 */
  private rememberTrackpad(): void {
    if (this.params.pcId.length === 0) {
      return;
    }
    try {
      PCStore.setTrackpad(this.ctx(), this.params.pcId, this.trackpadMode);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HMRDP 记住触控板模式失败: code=${err.code}`);
    }
  }

  /** 按本台电脑选定的文件夹解析共享盘（需权限，主页启动时申请）；未选/未授权则不挂盘 */
  private resolveShareDrives(): HmDriveEntry[] {
    const path = resolveSharePath(this.params.shareDir);
    console.info(`HMRDP drive shareDir=${JSON.stringify(this.params.shareDir ?? {})} resolved=${path ?? '(空)'}`);
    if (!path) {
      return [];
    }
    const t = SHARE_TARGETS.find((x) => x.key === (this.params.shareDir?.base ?? ''));
    return [{ name: t ? t.label : '共享', path: path }];
  }

  // ---- 共享剪贴板（cliprdr 桥接系统剪贴板）----

  private setupClipboard(): void {
    if (this.clipListening) {
      return;
    }
    try {
      pasteboard.getSystemPasteboard().on('update', this.clipUpdateHandler);
      this.clipListening = true;
      this.onLocalClipboardChanged(); // 连接后先把当前本地剪贴板推给远端
    } catch (e) {
      // 忽略：剪贴板不可用时功能降级
    }
  }

  private teardownClipboard(): void {
    if (!this.clipListening) {
      return;
    }
    try {
      pasteboard.getSystemPasteboard().off('update', this.clipUpdateHandler);
    } catch (e) {
    }
    this.clipListening = false;
  }

  /** 本地剪贴板变更 -> 广告给远端 */
  private onLocalClipboardChanged(): void {
    if (this.clipSelfWrite) {
      this.clipSelfWrite = false; // 本次 update 由远端写入触发，跳过读取避免回声与多余提示
      return;
    }
    try {
      pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
        this.maybeSendImage(data); // 图片优先：有 PixelMap 记录则编码 PNG 推远端
        const text = data.getPrimaryText();
        if (!text || text === this.clipLast) {
          return;
        }
        this.clipLast = text;
        hmrdp.setClipboardText(text);
      }).catch(() => {
      });
    } catch (e) {
    }
  }

  /** 本地剪贴板图片 -> 编码 PNG 推给远端（仅处理首个 PixelMap 记录） */
  private maybeSendImage(data: pasteboard.PasteData): void {
    try {
      const count = data.getRecordCount();
      let mimes: string = '';
      for (let i = 0; i < count; i++) {
        const r = data.getRecord(i);
        mimes += r.mimeType + ';';
      }
      console.info(`HMRDP clip records=${count} mimes=[${mimes}]`);
      for (let i = 0; i < count; i++) {
        const rec = data.getRecord(i);
        if (rec.mimeType === pasteboard.MIMETYPE_PIXELMAP) {
          const pm: image.PixelMap = rec.pixelMap;
          const packer = image.createImagePacker();
          packer.packToData(pm, { format: 'image/png', quality: 100 }).then((buf: ArrayBuffer) => {
            packer.release();
            const bytes = new Uint8Array(buf);
            console.info(`HMRDP clip image packed=${bytes.length}`);
            if (bytes.length === this.clipLastImage) {
              return; // 同尺寸，视为重复
            }
            this.clipLastImage = bytes.length;
            this.clipLast = ''; // 新图片到来，清空文本去重避免误判
            hmrdp.setClipboardImage(bytes);
          }).catch((e: Object) => {
            packer.release();
            console.info(`HMRDP clip image pack fail: ${JSON.stringify(e)}`);
          });
          return;
        }
      }
    } catch (e) {
    }
  }

  /** 远端剪贴板文本 -> 写入本地系统剪贴板 */
  private onClipFromRemote(text: string): void {
    if (!text || text === this.clipLast) {
      return;
    }
    this.clipLast = text;
    this.clipSelfWrite = true;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).catch(() => {
        this.clipSelfWrite = false;
      });
    } catch (e) {
      this.clipSelfWrite = false;
    }
  }

  /** 远端剪贴板图片(PNG) -> 解码为 PixelMap 写入本地系统剪贴板 */
  private onClipImageFromRemote(bytes: Uint8Array): void {
    if (!bytes || bytes.length === 0) {
      return;
    }
    this.clipSelfWrite = true;
    this.clipLastImage = bytes.length;
    this.clipLast = '';
    try {
      const source = image.createImageSource(bytes.buffer);
      source.createPixelMap().then((pm: image.PixelMap) => {
        const data = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pm);
        pasteboard.getSystemPasteboard().setData(data).catch(() => {
          this.clipSelfWrite = false;
        });
        source.release();
      }).catch(() => {
        this.clipSelfWrite = false;
        source.release();
      });
    } catch (e) {
      this.clipSelfWrite = false;
    }
  }

  private onCertRequest(request: HmCertRequest): void {
    const saved = CertStore.get(this.ctx(), request.host, request.port);
    if (!request.changed && saved === request.fingerprint) {
      hmrdp.respondCert(2);
      return;
    }
    const fpShort = request.fingerprint.length > 60
      ? `${request.fingerprint.substring(0, 60)}…` : request.fingerprint;
    this.getUIContext().showAlertDialog({
      title: request.changed ? '服务器证书已变更' : '验证服务器证书',
      message: (request.changed ? '警告：这台电脑的证书与上次连接时不一致，可能存在安全风险。\n\n' : '无法验证这台电脑的身份（通常是因为使用了自签名证书）。\n\n')
        + `服务器：${request.host}:${request.port}\n`
        + `名称：${request.commonName}\n`
        + `指纹：${fpShort}`,
      autoCancel: false,
      primaryButton: {
        value: '取消',
        action: () => {
          hmrdp.respondCert(0);
        }
      },
      secondaryButton: {
        value: '信任并连接',
        fontColor: request.changed ? $r('sys.color.warning') : $r('sys.color.brand'),
        action: () => {
          CertStore.trust(this.ctx(), request.host, request.port, request.fingerprint);
          hmrdp.respondCert(2);
        }
      }
    });
  }

  // ---- 软键盘上方的功能键条（软键盘没有 Esc/方向键/Home/PgUp/F 区，远程桌面离不开）----

  /** 底部键盘区总高；画面最多上推这么多 */
  private panLimit(): number {
    if (this.softKb) {
      return SOFT_KB_H;
    }
    if (this.kbHeight <= 0) {
      return 0;
    }
    return this.kbHeight + (this.imeBarFolded ? IME_HANDLE_H : IME_BAR_H);
  }

  /** 工具条抬到键盘区上方。功能键横条只有 82vp，抬上去也不会顶出屏幕，
   *  工具条就不用像之前那样为了躲开右侧面板而横向挪位了 */
  private toolbarBottom(): number {
    return 40 + this.panLimit();
  }

  /** 当前粘滞按下的修饰键 */
  private activeMods(): ModKey[] {
    const out: ModKey[] = [];
    for (let i = 0; i < MOD_KEYS.length; i++) {
      if ((this.stickyMods & (1 << i)) !== 0) {
        out.push(MOD_KEYS[i]);
      }
    }
    return out;
  }

  /** 带上粘滞修饰键发一个键（按下、抬起，修饰键逆序松开），随后清空修饰键——
   *  粘滞只作用于下一个键，和手机输入法的 Shift 一个语义 */
  private sendWithMods(code: number, ext: boolean, needShift: boolean = false): void {
    const mods = this.activeMods();
    // needShift：{ } | ~ _ + 这类键本身就是 Shift 变体，粘滞里没按 Shift 时临时补一个
    const extraShift = needShift && (this.stickyMods & MOD_SHIFT_BIT) === 0;
    for (const m of mods) {
      hmrdp.sendScancode(m.code, m.ext, true);
    }
    if (extraShift) {
      hmrdp.sendScancode(0x2A, false, true);
    }
    hmrdp.sendScancode(code, ext, true);
    hmrdp.sendScancode(code, ext, false);
    if (extraShift) {
      hmrdp.sendScancode(0x2A, false, false);
    }
    for (let i = mods.length - 1; i >= 0; i--) {
      hmrdp.sendScancode(mods[i].code, mods[i].ext, false);
    }
    if (this.stickyMods !== 0) {
      this.stickyMods = 0; // 粘滞只作用于下一个键
    }
  }

  /** 键盘区高度变化后，把已上推的画面收回到新范围内（键盘收起则归位） */
  private clampShift(): void {
    const limit = this.panLimit();
    if (this.kbShift > limit) {
      this.kbShift = limit;
    }
  }

  /** 紧凑键盘 / 导航面板的动作键 */
  private onSoftAction(act: number): void {
    if (act === ACT_IME) {
      // 打中文：让位给系统输入法（它带候选词，自绘的替代不了）。
      // 这里**不能** clampShift：系统键盘还没弹出，panLimit 此刻是 0，一收画面就弹回原位；
      // 等键盘高度回调到了，遮挡反而更高，本就不需要收
      this.softKb = false;
      this.showKeyboard();
    } else if (act === ACT_ABC) {
      // 从系统输入法切回紧凑键盘。先置位再收键盘，收起回调里按紧凑键盘的高度收画面
      this.softKb = true;
      this.hideKeyboard();
    } else if (act === ACT_FOLD) {
      this.imeBarFolded = !this.imeBarFolded;
      this.clampShift();
    }
  }

  /** 键盘/导航面板上的双指竖拖：它们盖着画面，手指落在上面也得能把画面推上去。
   *  触摸本来就不会传给 XComponent，所以不必动 setGestureActive */
  private onPanelPan(phase: number, dy: number): void {
    if (phase === PAN_START) {
      if (this.panLimit() <= 0 || this.kbPanFingers !== 0) {
        return;
      }
      this.kbPanFingers = 2;
      this.baseKbShift = this.kbShift;
    } else if (phase === PAN_UPDATE) {
      if (this.kbPanFingers === 2) {
        this.kbShift = Math.min(this.panLimit(), Math.max(0, this.baseKbShift - dy));
      }
    } else if (this.kbPanFingers === 2) {
      this.kbPanFingers = 0;
    }
  }

  /** 工具条「键盘」：在紧凑键盘 / 收起之间切换；系统输入法开着时先收它 */
  private toggleKeyboard(): void {
    if (this.keyboardShown) {
      this.hideKeyboard(); // 收起回调里会把画面收回去
      this.softKb = false;
      return;
    }
    this.softKb = !this.softKb;
    this.stickyMods = 0;
    this.clampShift();
  }

  /** 软键盘打出的字符：无修饰键时走 Unicode（中文/符号都靠它），
   *  有粘滞修饰键时转成扫描码组合，这样 Ctrl+C / Ctrl+V 这类才真正能用 */
  private onInsertText(text: string): void {
    if (this.stickyMods !== 0 && text.length === 1) {
      const c = text.charCodeAt(0);
      let sc = 0;
      if (c >= 0x61 && c <= 0x7A) {
        sc = SC_LETTERS[c - 0x61]; // a-z
      } else if (c >= 0x41 && c <= 0x5A) {
        sc = SC_LETTERS[c - 0x41]; // A-Z
      } else if (c >= 0x30 && c <= 0x39) {
        sc = SC_DIGITS[c - 0x30];
      }
      if (sc !== 0) {
        this.sendWithMods(sc, false);
        return;
      }
    }
    for (let i = 0; i < text.length; i++) {
      hmrdp.sendUnicode(text.charCodeAt(i));
    }
  }

  /** 监听软键盘高度：既拿到可上推的范围，也能感知用户用输入法自己的按钮收起了键盘 */
  private async setupKeyboardWatch(): Promise<void> {
    try {
      this.kbWin = await window.getLastWindow(this.ctx());
      this.kbWin.on('keyboardHeightChange', this.kbHeightCb);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HMRDP 监听键盘高度失败: code=${err.code}`);
    }
  }

  private teardownKeyboardWatch(): void {
    if (this.kbWin) {
      try {
        this.kbWin.off('keyboardHeightChange', this.kbHeightCb);
      } catch (e) {
      }
      this.kbWin = undefined;
    }
  }

  private onKeyboardHeight(px: number): void {
    const vp = px > 0 ? this.getUIContext().px2vp(px) : 0;
    console.info(`HMRDP keyboard height px=${px} vp=${vp}`);
    this.kbHeight = vp;
    if (vp <= 0) {
      // 键盘收起（含输入法自己的收起按钮）：状态同步。画面按「现在还剩多少遮挡」来收——
      // 切回紧凑键盘时它还挡着 156vp，直接归零会让画面白弹一下
      this.keyboardShown = false;
      this.stickyMods = 0;
      this.clampShift();
    } else {
      this.keyboardShown = true;
      this.kbShift = Math.min(this.kbShift, this.panLimit());
    }
  }

  /** 键盘弹出期间是否由本手势上推画面：一律双指竖向拖。
   *  不用单指——单指在触控板模式是移指针、在直接触摸模式是点击/拖拽，两种模式的核心操作都被占；
   *  而且常驻一个单指竖向 PanGesture 会打乱原生 XComponent 的触摸投递（触控板指针上下走发跳）。 */
  private kbPanAllowed(fingers: number): boolean {
    if (this.panLimit() <= 0 || this.isPc) {
      return false;
    }
    return fingers === 2;
  }

  /** fingers = 该 PanGesture 声明的指数；event 用来核对实际落下的指数 */
  private kbPanStart(fingers: number, event: GestureEvent): boolean {
    if (this.kbPanFingers !== 0 || event.fingerList.length !== fingers || !this.kbPanAllowed(fingers)) {
      return false;
    }
    this.kbPanFingers = fingers;
    this.baseKbShift = this.kbShift;
    hmrdp.setGestureActive(true); // 这段触摸不再转成远端鼠标事件
    return true;
  }

  private kbPanUpdate(fingers: number, dy: number): void {
    if (this.kbPanFingers !== fingers) {
      return;
    }
    // 手指上滑（dy<0）→ 画面上推；范围 [0, 键盘+功能键条高度]
    this.kbShift = Math.min(this.panLimit(), Math.max(0, this.baseKbShift - dy));
  }

  private kbPanEnd(fingers: number): void {
    if (this.kbPanFingers !== fingers) {
      return;
    }
    this.kbPanFingers = 0;
    hmrdp.setGestureActive(false);
  }

  private async showKeyboard(): Promise<void> {
    const controller = inputMethod.getController();
    if (!this.imeAttached) {
      await controller.attach(true, {
        inputAttribute: {
          textInputType: inputMethod.TextInputType.TEXT,
          enterKeyType: inputMethod.EnterKeyType.UNSPECIFIED
        }
      });
      controller.on('insertText', (text: string) => {
        this.onInsertText(text);
      });
      controller.on('deleteLeft', (length: number) => {
        for (let i = 0; i < length; i++) {
          hmrdp.sendScancode(SC_BACKSPACE, false, true);
          hmrdp.sendScancode(SC_BACKSPACE, false, false);
        }
      });
      controller.on('sendFunctionKey', (functionKey: inputMethod.FunctionKey) => {
        hmrdp.sendScancode(SC_ENTER, false, true);
        hmrdp.sendScancode(SC_ENTER, false, false);
      });
      this.imeAttached = true;
    } else {
      await controller.showTextInput();
    }
    this.keyboardShown = true;
  }

  private async hideKeyboard(): Promise<void> {
    const controller = inputMethod.getController();
    if (this.imeAttached) {
      await controller.hideTextInput();
    }
    this.keyboardShown = false;
  }

  private releaseKeyboard(): void {
    if (this.imeAttached) {
      const controller = inputMethod.getController();
      controller.off('insertText');
      controller.off('deleteLeft');
      controller.off('sendFunctionKey');
      controller.detach((err) => {
      });
      this.imeAttached = false;
    }
  }

  private startConnect(): void {
    let scale = this.params.scale;
    if (scale === 0) {
      scale = defaultScalePercent(); // 手机取密度一半、平板 3/4、PC 原样，见 DeviceKit
    }
    scale = Math.min(500, Math.max(100, scale));

    // 分辨率跟随本机：width/height 为 0（跟随窗口/全屏）时启用动态分辨率（disp 随窗口精修）
    const dynamic = (this.params.width === 0 || this.params.height === 0);
    let initW = dynamic ? 0 : this.params.width;
    let initH = dynamic ? 0 : this.params.height;
    if (dynamic) {
      // 会话恒横屏，但 getDefaultDisplaySync() 返回的是设备自然方向（手机=竖屏 1320×2232）的
      // 宽高。之前直接拿来当初值，等于把竖屏分辨率塞给远端，横屏 surface 一填充就横向拉伸
      // （Windows 的方形「最大化」按钮被压成扁矩形即此症状）。取长边作宽、短边作高，先给一个
      // 横屏正确的初值；动态分辨率随后按真实窗口尺寸精修。即便远端不支持 disp，比例也不会错。
      try {
        const d = display.getDefaultDisplaySync();
        initW = Math.max(d.width, d.height);
        initH = Math.min(d.width, d.height);
      } catch (e) {
        initW = 0;
        initH = 0;
      }
    }
    const config: HmConnectConfig = {
      host: this.params.host,
      port: this.params.port,
      username: this.params.username,
      password: this.params.password,
      domain: this.params.domain,
      width: initW,
      height: initH,
      scale: scale,
      dynamic: dynamic ? 1 : 0,
      drives: this.resolveShareDrives() // 磁盘重定向：选定的本地文件夹挂成远端网络盘
    };
    console.info(`HMRDP connect w=${initW} h=${initH} dynamic=${dynamic} fullscreen=${this.params.fullscreen} userW=${this.params.width} userH=${this.params.height} view=${this.viewW}x${this.viewH}vp`);
    this.errorText = '';
    this.statusText = '正在连接…';
    hmrdp.setTouchMode(this.trackpadMode); // 同步全局触摸映射器状态
    const ok: boolean = hmrdp.connect(config, (state: number, message: string) => {
      this.onSessionState(state, message);
    }, (request: HmCertRequest) => {
      this.onCertRequest(request);
    }, (text: string) => {
      this.onClipFromRemote(text);
    }, (bytes: Uint8Array) => {
      this.onClipImageFromRemote(bytes);
    });
    if (!ok) {
      this.errorText = '无法启动会话（可能已有连接未结束）';
    }
  }

  private onSessionState(state: number, message: string): void {
    if (state === STATE_CONNECTING) {
      this.statusText = '正在连接…';
    } else if (state === STATE_CONNECTED) {
      this.connected = true;
      this.errorText = '';
      this.setupClipboard();
      if (!this.isPc) {
        this.setupKeyboardWatch(); // 软键盘高度：上推画面的范围 + 工具条抬升
      }
      // 让主窗口能探测到这个会话：关闭主窗口前会据此提示「会断开全部连接」
      this.aliveResponder.start(this.params.host);
      if (this.isPc) {
        // 抢占物理键盘全键盘直通（含 Win 键）；拿到拦截态后内部再武装返回桌面热键
        this.setupKeyInterception();
      }
    } else if (state === STATE_DISCONNECTED) {
      this.connected = false;
      if (this.closing) {
        return;
      }
      if (message.length === 0 || message.includes('CONNECT_CANCELLED') ||
        message.includes('DISCONNECT_BY_USER') || message.includes('LOGOFF_BY_USER')) {
        this.leave(friendlyError(message));
      } else {
        this.errorText = friendlyError(message); // 显示错误面板，可重试
      }
    }
  }

  private leave(message: string): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    if (message.length > 0) {
      try {
        promptAction.showToast({ message: message, duration: 2500 });
      } catch (e) {
        // ignore
      }
    }
    if (this.params.standalone) {
      // 独立会话窗口：断开即关闭该窗口/Ability
      try {
        (this.ctx() as common.UIAbilityContext).terminateSelf();
      } catch (e) {
        this.pathStack?.pop();
      }
    } else {
      this.pathStack?.pop();
    }
  }

  @Builder
  sessionToolbar() {
    Row() {
      if (this.toolbarExpanded) {
        Row({ space: 2 }) {
          // 放在最左、与「断开」隔开：全屏会话没有标题栏出口，这是回鸿蒙桌面的唯一按钮，
          // 挨着「断开」容易点错。图标用系统符号 circle：SDK 没有鸿蒙 logo 符号，
          // 自绘华为商标又有上架审核风险，圆环是最接近且安全的表达
          if (this.isPc) {
            ToolButton({ symbol: $r('sys.symbol.circle'), label: '回鸿蒙', active: false,
              bold: true, iconSize: 20,
              action: () => { this.minimizeWindow(); } })
          }
          // PC/2in1 有物理键鼠，隐藏触摸相关的软件控制（键盘/触控板/复位）
          if (!this.isPc) {
            ToolButton({ symbol: $r('sys.symbol.keyboard'), label: '键盘',
              active: this.softKb || this.keyboardShown,
              action: () => { this.toggleKeyboard(); } })
            ToolButton({ symbol: $r('sys.symbol.hand_point_up_tap_fill'),
              label: this.trackpadMode ? '触控板' : '直接触摸', active: this.trackpadMode,
              action: () => {
                this.trackpadMode = !this.trackpadMode;
                hmrdp.setTouchMode(this.trackpadMode);
                this.rememberTrackpad();
                this.resetZoom();
                promptAction.showToast({ message: this.trackpadMode ? '触控板模式' : '直接触摸模式' });
              } })
            ToolButton({ symbol: $r('sys.symbol.arrow_counterclockwise'), label: '复位', active: false,
              action: () => { this.resetZoom(); } })
          }
          // 系统键：所有设备都显示——PC 上物理 Win/系统组合键被鸿蒙拦截，只能靠它代发
          Column({ space: 2 }) {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(22)
              .fontColor([Color.White])
            Text('系统键')
              .fontSize(10)
              .fontColor(Color.White)
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .bindMenu(this.systemKeysMenu())
          // 多显示器（外接屏/投屏）：选择把会话窗口放到哪块屏上
          if (this.isPc && this.displays.length > 1) {
            Column({ space: 2 }) {
              SymbolGlyph($r('sys.symbol.display'))
                .fontSize(22)
                .fontColor([Color.White])
              Text('屏幕')
                .fontSize(10)
                .fontColor(Color.White)
            }
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .bindMenu(this.displayMenu())
          }
          // 全屏切换：仅手机/平板；PC 会话窗口由 SessionAbility 统一全屏管理
          if (!this.isPc) {
            ToolButton({
              symbol: this.fullscreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left')
                                      : $r('sys.symbol.arrow_up_left_and_arrow_down_right'),
              label: this.fullscreen ? '退出全屏' : '全屏', active: this.fullscreen,
              action: () => { this.toggleFullscreen(); } })
          }
          ToolButton({ symbol: $r('sys.symbol.xmark'), label: '断开', active: false,
            action: () => { this.leave(''); } })
        }
      }
      ToolButton({
        symbol: this.toolbarExpanded ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_left'),
        label: this.toolbarExpanded ? '收起' : '展开', active: false,
        action: () => { this.toolbarExpanded = !this.toolbarExpanded; } })
    }
    .backgroundColor('#B3000000')
    .borderRadius(24)
    .padding(4)
    // 抬到键盘区上方，别被盖住
    .position({ right: 12, bottom: this.toolbarBottom() })
  }

  build() {
    NavDestination() {
      Stack() {
        XComponent({ id: 'rdp_surface', type: XComponentType.SURFACE, libraryname: 'hmrdp' })
          .width('100%')
          .height('100%')
          .focusable(true)
          .focusOnTouch(true)
          .defaultFocus(true)
          .scale({ x: this.viewScale, y: this.viewScale })
          .translate({ x: this.offsetX, y: this.offsetY - this.kbShift })
          .onAreaChange((_o: Area, n: Area) => {
            this.viewW = n.width as number;
            this.viewH = n.height as number;
            console.info(`HMRDP view area ${this.viewW}x${this.viewH}vp`);
          })
          .onLoad(() => {
            this.startConnect();
          })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  hmrdp.setGestureActive(true);
                  this.baseScale = this.viewScale;
                  this.baseOffsetX = this.offsetX;
                  this.baseOffsetY = this.offsetY;
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.viewScale = Math.min(4, Math.max(1, this.baseScale * event.scale));
                  this.clampOffsets();
                })
                .onActionEnd(() => {
                  if (this.viewScale <= 1.01) {
                    this.resetZoom();
                  }
                  hmrdp.setGestureActive(false);
                }),
              // 双指拖动：键盘弹出时上推画面，否则（缩放后）平移画面。
              // 两者都不成立时不接管触摸，否则原生的双指滚轮会被这里吃掉
              PanGesture({ fingers: 2 })
                .onActionStart((event: GestureEvent) => {
                  if (this.kbPanStart(2, event)) {
                    return;
                  }
                  if (this.viewScale > 1) {
                    hmrdp.setGestureActive(true);
                    this.baseOffsetX = this.offsetX;
                    this.baseOffsetY = this.offsetY;
                  }
                })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.kbPanFingers === 2) {
                    this.kbPanUpdate(2, event.offsetY as number);
                  } else if (this.viewScale > 1) {
                    this.offsetX = this.baseOffsetX + (event.offsetX as number);
                    this.offsetY = this.baseOffsetY + (event.offsetY as number);
                    this.clampOffsets();
                  }
                })
                .onActionEnd(() => {
                  if (this.kbPanFingers === 2) {
                    this.kbPanEnd(2);
                  } else if (this.viewScale > 1) {
                    hmrdp.setGestureActive(false);
                  }
                })
                .onActionCancel(() => {
                  if (this.kbPanFingers === 2) {
                    this.kbPanEnd(2);
                  } else if (this.viewScale > 1) {
                    hmrdp.setGestureActive(false);
                  }
                })
            )
          )
          .onAxisEvent((event: AxisEvent) => {
            // 竖向滚动轴值，带方向（鼠标滚轮与触摸板双指滚动均覆盖）。scrollStep 恒正、
            // 不带方向，只能当步长用，不能当位移用。方向若相反把两处的负号去掉。
            if (event.action === AxisAction.END || event.action === AxisAction.CANCEL) {
              this.wheelAccum = 0;
              return;
            }
            const v = event.getVerticalAxisValue();
            if (v === 0) {
              return;
            }
            if (this.wheelLogged < 5) {
              this.wheelLogged++;
              console.info(`HMRDP wheel tool=${event.sourceTool} action=${event.action} v=${v} step=${event.scrollStep}`);
            }
            if (event.sourceTool === SourceTool.MOUSE) {
              // 鼠标滚轮：系统对每个物理档位恰好上报一次轴事件，所以一次事件就发一档
              // WHEEL_DELTA(120)，与宿主机滚一格滚同样行数，1:1 不放大。
              this.wheelUnit = Math.abs(v); // 记下一档的轴值量纲，供触摸板折算
              this.wheelAccum = 0;
              hmrdp.sendWheel(v > 0 ? -120 : 120, event.x, event.y);
              return;
            }
            // 触摸板双指滚动是连续量，按“一档轴值”折算成档数，凑满整档才下发，
            // 余量留到下次，既不会因截断丢滚动，也不会每帧都甩出一整档。
            const unit = this.wheelUnit > 0 ? this.wheelUnit : Math.max(1, event.scrollStep ?? 1);
            this.wheelAccum += -v / unit;
            const notches = Math.trunc(this.wheelAccum);
            if (notches !== 0) {
              this.wheelAccum -= notches;
              hmrdp.sendWheel(notches * 120, event.x, event.y);
            }
          })

        // 打中文时左侧字母区让位给系统输入法，右侧导航面板留在屏幕上继续用，
        // 并补一列 Ctrl/Alt/Shift/Win（紧凑键盘那列在左侧底行，这里没有了）
        // 打中文：功能键横条贴在系统键盘上沿，占满宽度。
        // 包一层原生容器再定位：position 这类布局属性直接挂在自定义组件上会落到它的
        // 包装节点，位置容易跑偏
        if (this.connected && this.kbHeight > 0 && !this.softKb) {
          Column() {
            ImeKeyBar({
              stickyMods: $stickyMods,
              collapsed: this.imeBarFolded,
              onKey: (code: number, ext: boolean, needShift: boolean) => {
                this.sendWithMods(code, ext, needShift);
              },
              onAction: (act: number) => { this.onSoftAction(act); },
              onPan: (phase: number, dy: number) => { this.onPanelPan(phase, dy); }
            })
          }
          .width('100%')
          .height(this.imeBarFolded ? IME_HANDLE_H : IME_BAR_H)
          .position({ left: 0, bottom: this.kbHeight })
        }

        if (this.connected && this.softKb) {
          Column() {
            SoftKeyboard({
              stickyMods: $stickyMods,
              onKey: (code: number, ext: boolean, needShift: boolean) => {
                this.sendWithMods(code, ext, needShift);
              },
              onAction: (act: number) => { this.onSoftAction(act); },
              onPan: (phase: number, dy: number) => { this.onPanelPan(phase, dy); }
            })
          }
          .width('100%')
          .height(SOFT_KB_H)
          .position({ left: 0, bottom: 0 })
        }

        if (this.connected) {
          this.sessionToolbar()
        }

        if (!this.connected) {
          Column({ space: 12 }) {
            if (this.errorText.length === 0) {
              LoadingProgress()
                .width(48)
                .height(48)
                .color(Color.White)
              Text(this.statusText)
                .fontColor(Color.White)
                .fontSize(14)
            } else {
              SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
                .fontSize(52)
                .fontColor(['#E05555'])
              Text(this.errorText)
                .fontColor(Color.White)
                .fontSize(15)
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              Row({ space: 16 }) {
                Button('返回')
                  .buttonStyle(ButtonStyleMode.NORMAL)
                  .onClick(() => {
                    this.leave('');
                  })
                Button('重试')
                  .onClick(() => {
                    this.startConnect();
                  })
              }
              .margin({ top: 12 })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#CC000000')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
      if (ctx.pathInfo.param instanceof SessionParams) {
        this.params = ctx.pathInfo.param as SessionParams;
      }
      // 恢复这台电脑上次选的触摸模式。onReady 早于 XComponent onLoad(startConnect)，
      // 那里会 setTouchMode 同步给原生，这里只需把 UI 状态摆正
      if (!this.isPc && this.params.trackpad) {
        this.trackpadMode = true;
      }
      // 应用内会话（手机/平板分栏）时隐藏列表栏；独立窗口不影响列表窗口
      if (!this.params.standalone) {
        AppStorage.setOrCreate('hmrdpInSession', true);
      }
      this.applyOrientation(true); // 手机/平板：会话横屏
      // 「全屏」分辨率档：进入会话即切沉浸式全屏
      if (this.params.fullscreen) {
        this.applyFullscreen(true);
      }
    })
    .onDisAppear(() => {
      if (!this.params.standalone) {
        AppStorage.setOrCreate('hmrdpInSession', false);
        if (this.fullscreen) {
          this.applyFullscreen(false); // 应用内会话退出时恢复系统栏；独立窗口整体关闭无需恢复
        }
        this.applyOrientation(false); // 退出会话回竖屏（列表页是竖屏设计）
      }
      if (this.isPc) {
        try {
          display.off('add', this.displayChangeCb);
          display.off('remove', this.displayChangeCb);
        } catch (e) {
        }
      }
      this.softKb = false;
      this.aliveResponder.stop();
      this.teardownClipboard();
      this.teardownKeyInterception();
      this.teardownKeyboardWatch();
      this.releaseKeyboard();
      hmrdp.disconnect();
    })
  }
}
