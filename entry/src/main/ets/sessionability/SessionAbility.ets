import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SessionParams } from '../model/SessionParams';

// 独立会话窗口：远控会话在单独的 UIAbility 窗口里运行（与电脑列表窗口分开）。
// 2in1 上默认最大化成独立全屏窗口。参数经 want.parameters 传入、LocalStorage 传给页面。
export default class SessionAbility extends UIAbility {
  private storage: LocalStorage = new LocalStorage();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // singleton 复用：更新参数（sessionEpoch 变化触发页面重连）
    this.applyWant(want);
  }

  private applyWant(want: Want): void {
    const p = want.parameters;
    if (!p) {
      return;
    }
    const sp = new SessionParams(
      p['host'] as string,
      p['port'] as number,
      p['username'] as string,
      p['password'] as string,
      (p['domain'] as string) ?? '');
    sp.width = (p['width'] as number) ?? 0;
    sp.height = (p['height'] as number) ?? 0;
    sp.scale = (p['scale'] as number) ?? 0;
    sp.fullscreen = (p['fullscreen'] as boolean) ?? false;
    const dirs = (p['shareDirs'] as string) ?? '';
    sp.shareDirs = dirs.length > 0 ? dirs.split(',') : [];
    sp.standalone = true;
    this.storage.setOrCreate('sessionParams', sp);
    this.storage.setOrCreate('sessionEpoch', Date.now());
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/SessionHost', this.storage, (err) => {
      if (err.code) {
        return;
      }
      // 2in1：会话窗口最大化成独立全屏窗口
      if (deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'pc') {
        windowStage.getMainWindow().then((win: window.Window) => {
          win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER)
            .catch((e: Object) => {
            });
          // 窗口置顶（对齐 OSEasy：WINDOW_TOPMOST），让会话窗口独占前台
          win.setWindowTopmost(true).catch((e: Object) => {
          });
        }).catch((e: Object) => {
        });
      }
    });
  }

  onDestroy(): void {
  }
}
