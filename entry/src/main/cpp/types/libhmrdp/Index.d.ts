export interface ConnectConfig {
  host: string;
  port?: number;
  username: string;
  password: string;
  domain?: string;
  /** 远端桌面分辨率；0 或缺省 = 跟随 surface 尺寸 */
  width?: number;
  height?: number;
  /** Windows 显示缩放百分比 [100, 500] */
  scale?: number;
}

export interface CertRequest {
  host: string;
  port: number;
  commonName: string;
  subject: string;
  issuer: string;
  fingerprint: string;
  /** true = 证书与之前不一致（可能存在风险） */
  changed: boolean;
}

/**
 * state: 0 连接中 / 1 已连接 / 2 已断开（message 为错误信息，正常断开为空）
 * onCert: 服务器证书需要确认时回调，必须调用 respondCert() 应答，否则 120s 后按拒绝处理
 */
export const connect: (config: ConnectConfig, onState: (state: number, message: string) => void,
  onCert: (request: CertRequest) => void) => boolean;
export const disconnect: () => void;
/** 应答证书确认：0=拒绝 1=永久接受 2=仅本次接受 */
export const respondCert: (decision: number) => void;
export const getVersion: () => string;
/** 发送一个 UTF-16 码元（按下+抬起），用于软键盘文本输入 */
export const sendUnicode: (utf16Unit: number) => void;
/** 发送 PS/2 扫描码（如 Backspace=0x0E, Enter=0x1C） */
export const sendScancode: (scancode: number, extended: boolean, down: boolean) => void;
