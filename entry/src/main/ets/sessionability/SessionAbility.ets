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
    // specified 模式：再次双击同一台电脑会路由到本实例并由系统唤到前台。
    // 目标还是同一台电脑时什么都不做——已连接的会话必须保持，不能 bump epoch 触发重连。
    const cur = this.storage.get<SessionParams>('sessionParams');
    const p = want.parameters;
    if (cur !== undefined && p !== undefined
      && cur.host === (p['host'] as string) && cur.port === (p['port'] as number)) {
      return;
    }
    this.applyWant(want); // 防御：key 含 host:port，正常不会带着另一台电脑的参数进来
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
    windowStage.loadContent('pages/SessionHost', this.storage, (err) => {
      if (err.code) {
        return;
      }
      this.enterImmersive(windowStage);
    });
  }

  /** 进入沉浸式全屏并禁止鼠标悬停底部/顶部唤出系统 Dock 与标题栏。
   *  ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER 是 API 20 的 maximize 入参，
   *  旧设备/形态调用失败则走 catch，退回系统默认全屏（Dock 仍可悬停）。 */
  private enterImmersive(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER)
        .catch(() => {
        });
    } catch (e) {
      // 忽略：不支持该入参的设备退回默认全屏
    }
  }

  onDestroy(): void {
  }
}
