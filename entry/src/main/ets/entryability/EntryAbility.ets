import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { process } from '@kit.ArkTS';

const TAG: string = 'HMRDP';

export default class EntryAbility extends UIAbility {
  private mainWin: window.Window | undefined = undefined;
  /** 保持同一个函数引用，off 时才能精确注销 */
  private willCloseCb: () => Promise<boolean> = () => {
    return this.confirmClose();
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'loadContent succeeded');
    });
    this.hookWindowClose(windowStage);
  }

  /** 拦截标题栏关闭按钮：还有会话在跑时先确认，避免一键把所有远程连接全断掉。
   *  windowWillClose 是 API 15 接口且只在点系统标题栏关闭按钮时触发，旧设备走 catch 忽略。 */
  private hookWindowClose(windowStage: window.WindowStage): void {
    try {
      this.mainWin = windowStage.getMainWindowSync();
      this.mainWin.on('windowWillClose', this.willCloseCb);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'windowWillClose 注册失败: code=%{public}d', err.code);
    }
  }

  /** 返回值语义见 @ohos.window：resolve(true) = 不关闭窗口，resolve(false) = 继续关闭 */
  private async confirmClose(): Promise<boolean> {
    let count = 0;
    try {
      count = await this.activeSessionCount();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, '查询会话进程失败: code=%{public}d', err.code);
      return false; // 数不出来就别拦着用户关窗
    }
    hilog.info(0x0000, TAG, '关闭主窗口：活跃会话数=%{public}d', count);
    if (count === 0) {
      return false;
    }
    if (!this.mainWin) {
      return false;
    }
    try {
      const result = await this.mainWin.getUIContext().getPromptAction().showDialog({
        title: '还有正在进行的远程连接',
        message: `当前有 ${count} 个远程桌面连接。关闭主窗口会断开全部连接。`,
        buttons: [
          { text: '取消', color: '#1E7FD9' },
          { text: '关闭并断开', color: '#E05555' }
        ]
      });
      return result.index === 0; // 取消 -> 不关闭
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, '关闭确认框失败: code=%{public}d', err.code);
      return false;
    }
  }

  /** 活跃会话数 = 本应用除自己以外的进程数。PC 上每个会话窗口都是独立进程
   *  （SessionAbility + NEW_PROCESS_ATTACH_TO_PARENT）。
   *  按 pid 排除自身而不是按进程名比对包名：主进程名不一定恰好等于包名，
   *  比错了会把自己算成会话，导致没有会话时也弹确认框。 */
  private async activeSessionCount(): Promise<number> {
    const processes = await this.context.getApplicationContext().getRunningProcessInformation();
    const selfPid = process.pid;
    const others = processes.filter((p) => p.pid !== selfPid);
    hilog.info(0x0000, TAG, '本应用进程: %{public}s (自身 pid=%{public}d)',
      processes.map((p) => `${p.processName}#${p.pid}`).join(', '), selfPid);
    return others.length;
  }

  onWindowStageDestroy(): void {
    if (this.mainWin) {
      try {
        this.mainWin.off('windowWillClose', this.willCloseCb);
      } catch (e) {
      }
      this.mainWin = undefined;
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }
}
