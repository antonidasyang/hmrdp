import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';

/** 是否为 PC / 2in1 形态（有物理键鼠，走桌面级交互）。 */
export function isPcDevice(): boolean {
  const t = deviceInfo.deviceType;
  return t === '2in1' || t === 'pc';
}

/** 大屏形态 = 平板，或折叠屏展开后的内屏。这类形态列表页也横屏；
 *  手机与折叠屏外屏则「列表竖屏、会话横屏」。
 *
 *  判据用显示区域短边的 vp 宽度（鸿蒙断点：>= 600vp 视为 MD/LG 大屏），
 *  而不是 deviceInfo.deviceType——折叠屏内外屏都上报 phone，靠 type 分不出来。
 *  折叠屏展开时短边通常 600vp 以上，折叠后不足，正好与需求吻合；
 *  再叠加 tablet 类型兜底，避免个别平板 density 异常导致误判。 */
export function isLargeScreen(): boolean {
  if (deviceInfo.deviceType === 'tablet') {
    return true;
  }
  try {
    const d = display.getDefaultDisplaySync();
    const density = d.densityPixels > 0 ? d.densityPixels : 1;
    const shortEdgeVp = Math.min(d.width, d.height) / density;
    return shortEdgeVp >= 600;
  } catch (e) {
    return false; // 取不到就按手机处理（列表竖屏）
  }
}

/** 折叠屏展开态（内屏）。仅用于日志与调试，判定统一走 isLargeScreen()。 */
export function isFoldExpanded(): boolean {
  try {
    if (!display.isFoldable()) {
      return false;
    }
    const s = display.getFoldStatus();
    return s === display.FoldStatus.FOLD_STATUS_EXPANDED ||
      s === display.FoldStatus.FOLD_STATUS_HALF_FOLDED;
  } catch (e) {
    return false;
  }
}
