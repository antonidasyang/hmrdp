import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { probeActiveSessions } from '../model/SessionProbe';

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
      hilog.info(0x0000, TAG, 'windowWillClose 已注册');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'windowWillClose 注册失败: code=%{public}d msg=%{public}s',
        err.code, err.message);
    }
  }

  /** 返回值语义见 @ohos.window：resolve(true) = 不关闭窗口，resolve(false) = 继续关闭 */
  private async confirmClose(): Promise<boolean> {
    hilog.info(0x0000, TAG, 'windowWillClose 触发');
    // 不能用 getRunningProcessInformation 数会话：实测它只返回调用方自己的进程
    // （真机日志只有 com.d2ssoft.hmrdp#29234，会话子进程没出现）。改用公共事件探测。
    let labels: string[] = [];
    try {
      labels = await probeActiveSessions(300);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, '探测活跃会话失败: code=%{public}d', err.code);
      return false; // 探不出来就别拦着用户关窗
    }
    hilog.info(0x0000, TAG, '关闭主窗口：活跃会话数=%{public}d', labels.length);
    if (labels.length === 0 || !this.mainWin) {
      return false;
    }
    const detail = labels.length <= 3 ? `（${labels.join('、')}）` : '';
    try {
      const result = await this.mainWin.getUIContext().getPromptAction().showDialog({
        title: '还有正在进行的远程连接',
        message: `当前有 ${labels.length} 个远程桌面连接${detail}。关闭主窗口会断开全部连接。`,
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
