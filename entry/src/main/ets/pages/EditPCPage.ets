import { SessionParams } from '../model/SessionParams';

@Component
export struct EditPCPage {
  @State hostname: string = '';
  @State username: string = '';
  @State password: string = '';
  private pathStack: NavPathStack | null = null;

  private connectNow(): void {
    if (this.hostname.trim().length === 0) {
      return;
    }
    let host = this.hostname.trim();
    let port = 3389;
    const idx = host.lastIndexOf(':');
    if (idx > 0 && host.indexOf(':') === idx) { // 排除 IPv6 裸地址
      const p = Number.parseInt(host.substring(idx + 1));
      if (!Number.isNaN(p) && p > 0 && p < 65536) {
        port = p;
        host = host.substring(0, idx);
      }
    }
    // M3a：这里改为保存电脑配置；当前先直连验证链路
    const params = new SessionParams(host, port, this.username.trim(), this.password);
    this.pathStack?.pushPathByName('session', params);
  }

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        TextInput({ placeholder: '电脑名或 IP 地址（如 192.168.1.10:3389）', text: this.hostname })
          .type(InputType.Normal)
          .onChange((v: string) => {
            this.hostname = v;
          })
        TextInput({ placeholder: '用户名（如 Administrator 或 user@domain）', text: this.username })
          .type(InputType.USER_NAME)
          .onChange((v: string) => {
            this.username = v;
          })
        TextInput({ placeholder: '密码', text: this.password })
          .type(InputType.Password)
          .onChange((v: string) => {
            this.password = v;
          })
        Button('连接')
          .width('100%')
          .margin({ top: 16 })
          .enabled(this.hostname.trim().length > 0)
          .onClick(() => {
            this.connectNow();
          })
        Blank()
      }
      .padding(16)
      .width('100%')
      .height('100%')
    }
    .title('添加电脑')
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}
