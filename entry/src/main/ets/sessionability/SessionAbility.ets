import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { SessionParams } from '../model/SessionParams';
import { ShareDir } from '../model/ShareFolders';

// 独立会话窗口：远控会话在单独的 UIAbility 窗口里运行（与电脑列表窗口分开）。
// 2in1 上默认最大化成独立全屏窗口。参数经 want.parameters 传入、LocalStorage 传给页面。
export default class SessionAbility extends UIAbility {
  private storage: LocalStorage = new LocalStorage();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // multiton 下一般不会复用实例；保留以防同实例被再次拉起时刷新参数（sessionEpoch 触发重连）
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
    const sd = (p['shareDir'] as string) ?? '';
    if (sd.length > 0) {
      try {
        const obj = JSON.parse(sd) as ShareDir;
        sp.shareDir = { base: obj.base, sub: obj.sub };
      } catch (e) {
        sp.shareDir = undefined;
      }
    } else {
      sp.shareDir = undefined;
    }
    sp.standalone = true;
    this.storage.setOrCreate('sessionParams', sp);
    this.storage.setOrCreate('sessionEpoch', Date.now());
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 该 Ability 在 module.json5 声明 supportWindowMode=["fullscreen"]：
    // 2in1 上系统会将其作为全屏应用、自动开进独立桌面（对齐 OSEasy 的 VirtualAbility）。
    // 因此这里不再 maximize（那会降级为带任务栏的最大化态，反而破坏独立桌面）。
    windowStage.loadContent('pages/SessionHost', this.storage, (err) => {
      if (err.code) {
        return;
      }
    });
  }

  onDestroy(): void {
  }
}
