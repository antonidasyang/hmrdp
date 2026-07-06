import { display, promptAction } from '@kit.ArkUI';
import hmrdp from 'libhmrdp.so';
import { SessionParams } from '../model/SessionParams';

// libhmrdp.so 的 ConnectConfig 本地镜像（.so 具名类型导入在部分 SDK 版本不稳定）
interface HmConnectConfig {
  host: string;
  port: number;
  username: string;
  password: string;
  domain: string;
  scale: number;
}

const STATE_CONNECTING = 0;
const STATE_CONNECTED = 1;
const STATE_DISCONNECTED = 2;

@Component
export struct SessionPage {
  @State statusText: string = '正在连接…';
  @State connected: boolean = false;
  private pathStack: NavPathStack | null = null;
  private params: SessionParams = new SessionParams();
  private closing: boolean = false;

  private startConnect(): void {
    let scale = 100;
    try {
      scale = Math.round(display.getDefaultDisplaySync().densityPixels * 100);
    } catch (e) {
      scale = 100;
    }
    scale = Math.min(500, Math.max(100, scale));

    const config: HmConnectConfig = {
      host: this.params.host,
      port: this.params.port,
      username: this.params.username,
      password: this.params.password,
      domain: this.params.domain,
      scale: scale
    };
    const ok: boolean = hmrdp.connect(config, (state: number, message: string) => {
      this.onSessionState(state, message);
    });
    if (!ok) {
      this.statusText = '启动会话失败';
      this.leave('无法启动会话');
    }
  }

  private onSessionState(state: number, message: string): void {
    if (state === STATE_CONNECTING) {
      this.statusText = '正在连接…';
    } else if (state === STATE_CONNECTED) {
      this.connected = true;
    } else if (state === STATE_DISCONNECTED) {
      this.connected = false;
      this.leave(message.length > 0 ? `连接已断开：${message}` : '连接已断开');
    }
  }

  private leave(message: string): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    try {
      promptAction.showToast({ message: message, duration: 2500 });
    } catch (e) {
      // ignore
    }
    this.pathStack?.pop();
  }

  build() {
    NavDestination() {
      Stack() {
        XComponent({ id: 'rdp_surface', type: XComponentType.SURFACE, libraryname: 'hmrdp' })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            this.startConnect();
          })

        if (!this.connected) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(Color.White)
            Text(this.statusText)
              .fontColor(Color.White)
              .fontSize(14)
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
      hmrdp.disconnect();
    })
  }
}
