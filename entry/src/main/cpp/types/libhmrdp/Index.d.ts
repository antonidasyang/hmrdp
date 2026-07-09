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
  /** 1 = 启用动态分辨率（disp 通道，远端跟随本机窗口） */
  dynamic?: number;
  /** 磁盘重定向：把本地目录挂成远端网络盘（name=盘名, path=本地绝对路径） */
  drives?: Array<{ name: string; path: string }>;
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
 * onClip: （可选）远端剪贴板文本变更时回调，用于写入本地系统剪贴板
 */
export const connect: (config: ConnectConfig, onState: (state: number, message: string) => void,
  onCert: (request: CertRequest) => void, onClip?: (text: string) => void) => boolean;
export const disconnect: () => void;
/** 动态分辨率：请求远端桌面尺寸（一般由原生随 surface 变化自动调用） */
export const requestResize: (width: number, height: number) => void;
/** 本地剪贴板文本变更时调用，向远端广告文本格式 */
export const setClipboardText: (text: string) => void;
/** 开/关物理键盘全局拦截（把含 Win 的全键盘转发远端）。返回是否处于拦截态；
 *  需受限权限 INTERCEPT_INPUT_EVENT，未授权时恒 false（自动降级到系统键菜单/普通按键）。 */
export const setKeyInterception: (enable: boolean) => boolean;
/** 开/关触摸→鼠标映射（PC 上关掉避免和物理鼠标产生双击） */
export const setTouchEnabled: (enable: boolean) => void;
/** 鼠标滚轮（delta 正值向上，单位为标准滚轮档） */
export const sendWheel: (delta: number, x: number, y: number) => void;
/** 应答证书确认：0=拒绝 1=永久接受 2=仅本次接受 */
export const respondCert: (decision: number) => void;
/** 缩放/平移手势进行中时置 true，暂停触摸转鼠标，避免手势与点击互相干扰 */
export const setGestureActive: (active: boolean) => void;
/** 触摸操作模式：false 直接触摸（点哪是哪），true 触控板（相对指针） */
export const setTouchMode: (trackpad: boolean) => void;
export const getVersion: () => string;
/** 发送一个 UTF-16 码元（按下+抬起），用于软键盘文本输入 */
export const sendUnicode: (utf16Unit: number) => void;
/** 发送 PS/2 扫描码（如 Backspace=0x0E, Enter=0x1C） */
export const sendScancode: (scancode: number, extended: boolean, down: boolean) => void;
