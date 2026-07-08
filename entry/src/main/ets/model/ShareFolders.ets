// 可共享给远程电脑的本地目录（须与已申请的目录权限对应）
export interface ShareTarget {
  /** 存储用的稳定 key */
  key: string;
  label: string;
}

// 桌面目录权限是 system_basic 级，第三方拿不到，故只提供下载/文档
export const SHARE_TARGETS: ShareTarget[] = [
  { key: 'download', label: '下载' },
  { key: 'documents', label: '文档' }
];

/** 新建电脑默认共享的目录 */
export const DEFAULT_SHARE_DIRS: string[] = ['download', 'documents'];
