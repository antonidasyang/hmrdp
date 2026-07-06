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

/** state: 0 连接中 / 1 已连接 / 2 已断开（message 为错误信息，正常断开为空） */
export const connect: (config: ConnectConfig, onState: (state: number, message: string) => void) => boolean;
export const disconnect: () => void;
export const getVersion: () => string;
/** 发送一个 UTF-16 码元（按下+抬起），用于软键盘文本输入 */
export const sendUnicode: (utf16Unit: number) => void;
/** 发送 PS/2 扫描码（如 Backspace=0x0E, Enter=0x1C） */
export const sendScancode: (scancode: number, extended: boolean, down: boolean) => void;
