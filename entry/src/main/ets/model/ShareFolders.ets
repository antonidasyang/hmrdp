import { Environment } from '@kit.CoreFileKit';

// 可共享给远程电脑的本地目录（须与已申请的目录权限对应）
export interface ShareTarget {
  /** 存储用的稳定 key */
  key: string;
  label: string;
}

// 桌面目录权限 system_basic 需 ACL；未授权时 resolveSharePath 自动跳过该 base
export const SHARE_TARGETS: ShareTarget[] = [
  { key: 'download', label: '下载' },
  { key: 'documents', label: '文档' },
  { key: 'desktop', label: '桌面' }
];

/** per-PC 共享文件夹：base=SHARE_TARGETS 之一，sub=相对子路径（''=该目录根） */
export interface ShareDir {
  base: string;
  sub: string;
}

/** 新建电脑默认共享：下载目录根 */
export const DEFAULT_SHARE_DIR: ShareDir = { base: 'download', sub: '' };

/** 显示用标签，如「下载 > RDP-Share」或「未共享」 */
export function shareLabel(d: ShareDir | undefined): string {
  if (!d) {
    return '未共享';
  }
  const t = SHARE_TARGETS.find((x) => x.key === d.base);
  const base = t ? t.label : d.base;
  return d.sub.length > 0 ? `${base} > ${d.sub}` : base;
}

/** 解析为真实路径；权限未授/未知 base 返回 undefined */
export function resolveSharePath(d: ShareDir | undefined): string | undefined {
  if (!d) {
    return undefined;
  }
  let base: string;
  try {
    if (d.base === 'download') {
      base = Environment.getUserDownloadDir();
    } else if (d.base === 'documents') {
      base = Environment.getUserDocumentDir();
    } else if (d.base === 'desktop') {
      base = Environment.getUserDesktopDir();
    } else {
      return undefined;
    }
  } catch (e) {
    return undefined; // 未授权
  }
  if (!base || base.length === 0) {
    return undefined;
  }
  return d.sub.length > 0 ? `${base}/${d.sub}` : base;
}
