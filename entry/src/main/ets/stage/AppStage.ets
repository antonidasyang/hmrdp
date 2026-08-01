import { AbilityStage, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'HMRDP';

/** 会话窗口路由：一台电脑（host:port）最多一个会话窗口。
 *  SessionAbility 是 launchType=specified：系统每次启动前先问 onAcceptWant 要实例 key，
 *  key 已有存活实例 → 不新建，直接把那个窗口唤到前台（触发其 onNewWant）；否则新建。
 *  isolationProcess=true 时新实例进程由 onNewProcessRequest 决定：每台电脑一个独立进程，
 *  native 全局会话（g_session/键盘拦截）互不干扰，支持同时连多台电脑（仅 2in1 支持）。 */
export default class AppStage extends AbilityStage {
  private sessionKey(want: Want): string {
    const p = want.parameters;
    const host = p !== undefined ? `${p['host']}` : '';
    const port = p !== undefined ? `${p['port']}` : '';
    return `session_${host}_${port}`;
  }

  onAcceptWant(want: Want): string {
    if (want.abilityName === 'SessionAbility') {
      const key = this.sessionKey(want);
      hilog.info(0x0000, TAG, '会话实例路由 key=%{public}s', key);
      return key;
    }
    return 'default';
  }

  onNewProcessRequest(want: Want): string {
    if (want.abilityName === 'SessionAbility') {
      return this.sessionKey(want);
    }
    return 'main';
  }
}
