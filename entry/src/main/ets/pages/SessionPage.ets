import { display, promptAction } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { common } from '@kit.AbilityKit';
import hmrdp from 'libhmrdp.so';
import { SessionParams } from '../model/SessionParams';
import { CertStore } from '../model/CertStore';

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
}

const STATE_CONNECTING = 0;
const STATE_CONNECTED = 1;
const STATE_DISCONNECTED = 2;

@Component
export struct SessionPage {
  @State statusText: string = '正在连接…';
  @State connected: boolean = false;
  @State keyboardShown: boolean = false;
  @State errorText: string = '';
  @State toolbarExpanded: boolean = true;
  @State trackpadMode: boolean = false;
  // 视图缩放/平移（作用于 XComponent 显示，不改变远端分辨率）
  @State viewScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private baseScale: number = 1;
  private baseOffsetX: number = 0;
  private baseOffsetY: number = 0;
  private viewW: number = 0;
  private viewH: number = 0;
  private pathStack: NavPathStack | null = null;
  private params: SessionParams = new SessionParams();
  private closing: boolean = false;
  private imeAttached: boolean = false;

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
    // 大屏分栏时隐藏列表栏，让会话占满整窗
    AppStorage.setOrCreate('hmrdpInSession', true);
  }

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
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

    const config: HmConnectConfig = {
      host: this.params.host,
      port: this.params.port,
      username: this.params.username,
      password: this.params.password,
      domain: this.params.domain,
      width: this.params.width,
      height: this.params.height,
      scale: scale
    };
    this.errorText = '';
    this.statusText = '正在连接…';
    hmrdp.setTouchMode(this.trackpadMode); // 同步全局触摸映射器状态
    const ok: boolean = hmrdp.connect(config, (state: number, message: string) => {
      this.onSessionState(state, message);
    }, (request: HmCertRequest) => {
      this.onCertRequest(request);
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
    this.pathStack?.pop();
  }

  @Builder
  toolButton(symbol: Resource, label: string, active: boolean, action: () => void) {
    Column({ space: 2 }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor([active ? '#4DA3FF' : Color.White])
      Text(label)
        .fontSize(10)
        .fontColor(active ? '#4DA3FF' : Color.White)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .onClick(action)
  }

  @Builder
  sessionToolbar() {
    Row() {
      if (this.toolbarExpanded) {
        Row({ space: 2 }) {
          this.toolButton($r('sys.symbol.keyboard'), '键盘', this.keyboardShown, () => {
            if (this.keyboardShown) {
              this.hideKeyboard();
            } else {
              this.showKeyboard();
            }
          })
          this.toolButton($r('sys.symbol.hand_point_up_tap_fill'), this.trackpadMode ? '触控板' : '直接触摸',
            this.trackpadMode, () => {
              this.trackpadMode = !this.trackpadMode;
              hmrdp.setTouchMode(this.trackpadMode);
              this.resetZoom();
              promptAction.showToast({ message: this.trackpadMode ? '触控板模式' : '直接触摸模式' });
            })
          this.toolButton($r('sys.symbol.arrow_counterclockwise'), '复位', false, () => {
            this.resetZoom();
          })
          this.toolButton($r('sys.symbol.xmark'), '断开', false, () => {
            this.leave('');
          })
        }
      }
      this.toolButton(this.toolbarExpanded ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_left'),
        this.toolbarExpanded ? '收起' : '菜单', false, () => {
          this.toolbarExpanded = !this.toolbarExpanded;
        })
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
                  if (this.viewScale > 1) {
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
    })
    .onDisAppear(() => {
      AppStorage.setOrCreate('hmrdpInSession', false);
      this.releaseKeyboard();
      hmrdp.disconnect();
    })
  }
}
