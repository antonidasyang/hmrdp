// 会话页入参（NavPathStack param）
export class SessionParams {
  host: string = '';
  port: number = 3389;
  username: string = '';
  password: string = '';
  domain: string = '';

  constructor(host?: string, port?: number, username?: string, password?: string, domain?: string) {
    this.host = host ?? '';
    this.port = port ?? 3389;
    this.username = username ?? '';
    this.password = password ?? '';
    this.domain = domain ?? '';
  }
}
