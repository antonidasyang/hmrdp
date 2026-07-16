import { Environment } from '@kit.CoreFileKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';

// 可共享给远程电脑的本地目录（须与已申请的目录权限对应）
export interface ShareTarget {
  /** 存储用的稳定 key */
  key: string;
  label: string;
}

// 只保留三方应用可获授权的目录：桌面目录权限是 system_basic，三方拿不到，不再提供
export const SHARE_TARGETS: ShareTarget[] = [
  { key: 'download', label: '下载' },
  { key: 'documents', label: '文档' }
];

const FILE_PERMS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY'
];

/** 按使用场景申请「下载/文档」目录读写权限：仅在用户选择共享文件夹、或发起带共享目录的
 *  会话时调用，绝不在应用启动时申请（华为审核要求权限与场景绑定）。拒绝则回退应用沙箱。 */
export async function ensureFilePermissions(ctx: common.UIAbilityContext): Promise<void> {
  try {
    await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(ctx, FILE_PERMS);
  } catch (e) {
    // 忽略：用户拒绝则磁盘重定向回退到应用沙箱目录
  }
}

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
