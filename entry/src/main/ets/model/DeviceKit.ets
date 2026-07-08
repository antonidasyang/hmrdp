import { deviceInfo } from '@kit.BasicServicesKit';

/** 是否为 PC / 2in1 形态（有物理键鼠，走桌面级交互）。 */
export function isPcDevice(): boolean {
  const t = deviceInfo.deviceType;
  return t === '2in1' || t === 'pc';
}
