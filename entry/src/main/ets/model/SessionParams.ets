// 会话页入参（NavPathStack param）
export class SessionParams {
  host: string = '';
  port: number = 3389;
  username: string = '';
  password: string = '';
  domain: string = '';
  /** 远端桌面分辨率，0 = 跟随 surface */
  width: number = 0;
  height: number = 0;
  /** 显示缩放百分比，0 = 跟随设备 */
  scale: number = 0;
  /** 进入会话即切全屏（沉浸式） */
  fullscreen: boolean = false;
  /** 共享给远程的本地目录 key 列表（见 ShareFolders） */
  shareDirs: string[] = [];

  constructor(host?: string, port?: number, username?: string, password?: string, domain?: string) {
    this.host = host ?? '';
    this.port = port ?? 3389;
    this.username = username ?? '';
    this.password = password ?? '';
    this.domain = domain ?? '';
  }
}
