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

/** 「跟随设备」时的远端显示缩放（DesktopScaleFactor 百分比）。
 *
 *  直接拿 densityPixels×100 在手机上会得到 300%+：手机像素密度是按贴脸看设计的，
 *  远程桌面照搬会让可用面积缩到 900×400 级别，什么都摆不下。手机取密度的一半
 *  （3.25 → 175%），平板取 3/4，PC/2in1 像素密度本来就接近 Windows 的定义、原样用。
 *  结果就近落到 Windows 自己的档位（25% 一档），并夹到 [100, 500]。 */
export function defaultScalePercent(): number {
  let density = 1;
  try {
    density = display.getDefaultDisplaySync().densityPixels;
  } catch (e) {
    return 100;
  }
  if (!(density > 0)) {
    return 100;
  }
  let factor = 1;
  if (!isPcDevice()) {
    factor = isLargeScreen() ? 0.75 : 0.5;
  }
  const raw = density * 100 * factor;
  const snapped = Math.round(raw / 25) * 25;
  return Math.min(500, Math.max(100, snapped));
}
