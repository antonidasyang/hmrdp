import { display, promptAction, window } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { resolveSharePath, SHARE_TARGETS } from '../model/ShareFolders';
import hmrdp from 'libhmrdp.so';
import { SessionParams } from '../model/SessionParams';
import { CertStore } from '../model/CertStore';
import { isPcDevice } from '../model/DeviceKit';

const SC_BACKSPACE = 0x0E;
const SC_ENTER = 0x1C;

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
  action: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      SymbolGlyph(this.symbol)
        .fontSize(22)
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
  // 视图缩放/平移（作用于 XComponent 显示，不改变远端分辨率）
  @State viewScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  // 触控板四指横滑收起会话（模拟「滑回本地桌面」：鸿蒙无第二桌面，滑出动画+minimize 是 OSEasy 同款做法）
  @State swipeX: number = 0;
  private fourSwipe: boolean = false;
  private swipeBaseX: number = 0;
  private baseScale: number = 1;
  private baseOffsetX: number = 0;
  private baseOffsetY: number = 0;
  private viewW: number = 0;
  private viewH: number = 0;
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
    hmrdp.setKeyInterception(true);
    this.setFourSwipeMonitor(true);
  }

  private teardownKeyInterception(): void {
    hmrdp.setKeyInterception(false);
    this.setFourSwipeMonitor(false);
    if (this.keyWin) {
      try {
        this.keyWin.off('windowEvent', this.winEventCb);
      } catch (e) {
      }
      this.keyWin = undefined;
    }
  }

  private onWindowEvent(type: window.WindowEventType): void {
    // 失焦/隐藏即释放键盘与手势监听（用鼠标点其它窗口即可脱离）；重新聚焦且仍连接则恢复
    if (type === window.WindowEventType.WINDOW_INACTIVE || type === window.WindowEventType.WINDOW_HIDDEN) {
      hmrdp.setKeyInterception(false);
      this.setFourSwipeMonitor(false);
    } else if (type === window.WindowEventType.WINDOW_ACTIVE && this.connected) {
      hmrdp.setKeyInterception(true);
      this.setFourSwipeMonitor(true);
    }
  }

  // ---- 触控板四指横滑：收起会话窗口回本地桌面（OSEasy 同款模拟）----

  /** 仅 PC 独立会话窗口启用；需 INPUT_MONITORING 受限权限，未授权自动降级为不启用 */
  private setFourSwipeMonitor(enable: boolean): void {
    if (!this.isPc || !this.params.standalone) {
      return;
    }
    if (enable) {
      hmrdp.setTouchpadSwipeMonitor(true, (type: number, x: number, y: number) => {
        this.onFourSwipe(type, x, y);
      });
    } else {
      hmrdp.setTouchpadSwipeMonitor(false);
    }
  }

  private onFourSwipe(type: number, x: number, _y: number): void {
    // 诊断日志：真机首轮联调用（坐标量纲未在文档明确，据此调阈值/倍率）
    console.info(`HMRDP fourSwipe type=${type} x=${x}`);
    if (type === 1) { // BEGIN
      this.swipeBaseX = x;
      this.fourSwipe = true;
    } else if (type === 2) { // UPDATE
      if (this.fourSwipe) {
        this.swipeX = this.getUIContext().px2vp(x - this.swipeBaseX);
      }
    } else { // END / CANCEL
      this.finishFourSwipe();
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
        for (let i = 0; i < text.length; i++) {
          hmrdp.sendUnicode(text.charCodeAt(i));
        }
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
      try {
        scale = Math.round(display.getDefaultDisplaySync().densityPixels * 100);
      } catch (e) {
        scale = 100;
      }
    }
    scale = Math.min(500, Math.max(100, scale));

    // 分辨率跟随本机：width/height 为 0 时启用动态分辨率（disp 通道随窗口实时匹配）
    const dynamic = (this.params.width === 0 || this.params.height === 0);
    let initW = dynamic ? 0 : this.params.width;
    let initH = dynamic ? 0 : this.params.height;
    if (dynamic && this.params.fullscreen) {
      // 动态+全屏：初始用整屏分辨率，避免动态分辨率生效前偏低
      // 固定分辨率不覆盖，尊重用户选择
      try {
        const d = display.getDefaultDisplaySync();
        initW = d.width;
        initH = d.height;
      } catch (e) {
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
    console.info(`HMRDP connect w=${initW} h=${initH} dynamic=${dynamic} fullscreen=${this.params.fullscreen} userW=${this.params.width} userH=${this.params.height}`);
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
      if (this.isPc) {
        this.setupKeyInterception(); // PC：抢占物理键盘全键盘直通（含 Win 键）
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

  /** 四指横滑结束：超过阈值 → 滑出动画 + 最小化到桌面；否则回弹 */
  private finishFourSwipe(): void {
    if (!this.fourSwipe) {
      return;
    }
    this.fourSwipe = false;
    hmrdp.setGestureActive(false);
    const w = this.viewW > 0 ? this.viewW : 1280;
    // 触控板滑动行程有限，阈值取窗宽 1/5 与 160vp 的较小者
    const threshold = Math.min(w / 5, 160);
    if (Math.abs(this.swipeX) > threshold) {
      const dir = this.swipeX > 0 ? 1 : -1;
      this.getUIContext().animateTo({
        duration: 220,
        curve: Curve.EaseOut,
        onFinish: () => {
          this.minimizeToDesktop();
        }
      }, () => {
        this.swipeX = dir * w;
      });
    } else {
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.swipeX = 0;
      });
    }
  }

  /** 最小化会话窗口露出本地桌面。鸿蒙 PC 无第二桌面（WMS 只有唯一的
   *  WINDOW_TYPE_DESKTOP），「滑回桌面」只能用内容动画 + minimize 模拟。 */
  private minimizeToDesktop(): void {
    window.getLastWindow(this.ctx())
      .then((win: window.Window) => win.minimize())
      .then(() => {
        this.swipeX = 0; // 复位，恢复窗口时画面归位
      })
      .catch(() => {
        this.swipeX = 0;
      });
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
          // PC/2in1 有物理键鼠，隐藏触摸相关的软件控制（键盘/触控板/复位）
          if (!this.isPc) {
            ToolButton({ symbol: $r('sys.symbol.keyboard'), label: '键盘', active: this.keyboardShown,
              action: () => {
                if (this.keyboardShown) {
                  this.hideKeyboard();
                } else {
                  this.showKeyboard();
                }
              } })
            ToolButton({ symbol: $r('sys.symbol.hand_point_up_tap_fill'),
              label: this.trackpadMode ? '触控板' : '直接触摸', active: this.trackpadMode,
              action: () => {
                this.trackpadMode = !this.trackpadMode;
                hmrdp.setTouchMode(this.trackpadMode);
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
    .position({ right: 12, bottom: 40 })
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
          .translate({ x: this.offsetX, y: this.offsetY })
          .onAreaChange((_o: Area, n: Area) => {
            this.viewW = n.width as number;
            this.viewH = n.height as number;
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
                  if (this.fourSwipe) {
                    return; // 四指滑动进行中，忽略捏合（fingers 是"最少手指数"，四指也会触发它）
                  }
                  this.viewScale = Math.min(4, Math.max(1, this.baseScale * event.scale));
                  this.clampOffsets();
                })
                .onActionEnd(() => {
                  if (this.viewScale <= 1.01) {
                    this.resetZoom();
                  }
                  hmrdp.setGestureActive(false);
                }),
              // 双指拖动平移（缩放后才生效）
              PanGesture({ fingers: 2 })
                .onActionStart(() => {
                  hmrdp.setGestureActive(true);
                  this.baseOffsetX = this.offsetX;
                  this.baseOffsetY = this.offsetY;
                })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.viewScale > 1 && !this.fourSwipe) {
                    this.offsetX = this.baseOffsetX + (event.offsetX as number);
                    this.offsetY = this.baseOffsetY + (event.offsetY as number);
                    this.clampOffsets();
                  }
                })
                .onActionEnd(() => {
                  hmrdp.setGestureActive(false);
                })
            )
          )
          .onAxisEvent((event: AxisEvent) => {
            // 竖向滚动轴值，带方向（鼠标滚轮与触摸板双指滚动均覆盖）。scrollStep 仅鼠标滚轮
            // 携带、触摸板上恒正，会导致单向滚动，故改用 getVerticalAxisValue()。
            // 120 = 一档（Windows WHEEL_DELTA）。远端方向若与手指相反，把 -v 改成 v。
            const v = event.getVerticalAxisValue();
            if (v !== 0) {
              hmrdp.sendWheel(Math.trunc(-v * 120), event.x, event.y);
            }
          })

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
      .translate({ x: this.swipeX })
    }
    .backgroundColor(Color.Black)
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
      if (ctx.pathInfo.param instanceof SessionParams) {
        this.params = ctx.pathInfo.param as SessionParams;
      }
      // 应用内会话（手机/平板分栏）时隐藏列表栏；独立窗口不影响列表窗口
      if (!this.params.standalone) {
        AppStorage.setOrCreate('hmrdpInSession', true);
      }
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
      }
      this.teardownClipboard();
      this.teardownKeyInterception();
      this.releaseKeyboard();
      hmrdp.disconnect();
    })
  }
}
