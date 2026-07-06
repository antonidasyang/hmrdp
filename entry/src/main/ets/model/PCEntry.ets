// 已保存的电脑条目（可 JSON 序列化的纯数据）
export interface PCEntry {
  id: string;
  /** 友好名称，空则显示 host */
  name: string;
  host: string;
  port: number;
  username: string;
  /** 密码是否已保存到系统关键资产（Asset Store） */
  hasPassword: boolean;
  /** 远端桌面分辨率，0 = 跟随屏幕 */
  width: number;
  height: number;
  /** 显示缩放百分比，0 = 跟随设备 */
  scale: number;
  createdAt: number;
  lastUsedAt: number;
}

export function displayName(pc: PCEntry): string {
  return pc.name.length > 0 ? pc.name : pc.host;
}
