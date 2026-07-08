// 可复用的用户账号（凭据）。密码存系统关键资产，不进 JSON。
export interface AccountEntry {
  id: string;
  /** 显示名，如「公司 AD」；空则用 域\用户名 */
  label: string;
  username: string;
  domain: string;
  /** 密码是否已保存到 Asset Store */
  hasPassword: boolean;
}

export function accountDisplay(a: AccountEntry): string {
  if (a.label.length > 0) {
    return a.label;
  }
  return a.domain.length > 0 ? `${a.domain}\\${a.username}` : a.username;
}
