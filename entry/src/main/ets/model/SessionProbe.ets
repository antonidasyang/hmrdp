// 活跃会话探测（跨进程）。
// 背景：PC 上每个会话窗口是独立进程（SessionAbility + NEW_PROCESS_ATTACH_TO_PARENT），
// 而 ApplicationContext.getRunningProcessInformation() 实测只返回调用方自己的进程
// （真机日志：本应用进程: com.d2ssoft.hmrdp#29234，会话进程完全没出现），
// 所以主窗口无法靠进程列表判断有没有会话在跑。
// 改用公共事件做一次「探测—应答」：主窗口广播探测，活着的会话立刻应答。
// 无状态设计——不维护计数，会话崩溃也不会残留假数据。
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { process } from '@kit.ArkTS';

/** 只发给本应用的订阅方（CommonEventPublishData.bundleName 的语义是「能接收该事件的
 *  订阅方包名」）。应答里带着远程主机名，不能让其它应用订阅到。 */
const APP_BUNDLE = 'com.d2ssoft.hmrdp';
/** 主窗口 -> 会话：你还活着吗 */
const EVENT_PROBE = 'com.d2ssoft.hmrdp.session.probe';
/** 会话 -> 主窗口：我还活着（parameters 带 pid 与 label） */
const EVENT_ALIVE = 'com.d2ssoft.hmrdp.session.alive';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

function publishEvent(event: string, params?: Record<string, Object>): Promise<void> {
  return new Promise<void>((resolve) => {
    const options: commonEventManager.CommonEventPublishData = {
      bundleName: APP_BUNDLE,
      parameters: params
    };
    commonEventManager.publish(event, options, (err: BusinessError) => {
      if (err) {
        console.warn(`HMRDP 会话探测：发布 ${event} 失败 code=${err.code}`);
      }
      resolve();
    });
  });
}

/** 会话进程侧：连接期间订阅探测并应答。label 用于主窗口在确认框里显示是哪台电脑。 */
export class SessionAliveResponder {
  private subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private label: string = '';

  start(label: string): void {
    this.label = label;
    if (this.subscriber !== undefined) {
      return;
    }
    commonEventManager.createSubscriber({ events: [EVENT_PROBE] })
      .then((sub: commonEventManager.CommonEventSubscriber) => {
        this.subscriber = sub;
        commonEventManager.subscribe(sub, (err: BusinessError) => {
          if (err) {
            return;
          }
          const params: Record<string, Object> = {
            'pid': process.pid as Object,
            'label': this.label as Object
          };
          publishEvent(EVENT_ALIVE, params);
        });
        console.info('HMRDP 会话探测：已订阅存活探测');
      })
      .catch((e: BusinessError) => {
        console.warn(`HMRDP 会话探测：订阅失败 code=${e.code}`);
      });
  }

  stop(): void {
    const sub = this.subscriber;
    this.subscriber = undefined;
    if (sub === undefined) {
      return;
    }
    try {
      commonEventManager.unsubscribe(sub);
    } catch (e) {
      // 已失效，忽略
    }
  }
}

/** 主窗口侧：广播探测并收集应答，返回各活跃会话的显示名（按 pid 去重）。
 *  waitMs 是等待应答的窗口期，太短会漏、太长会让关窗发木；250~400ms 合适。 */
export async function probeActiveSessions(waitMs: number): Promise<string[]> {
  const found = new Map<number, string>();
  let subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  try {
    subscriber = await commonEventManager.createSubscriber({ events: [EVENT_ALIVE] });
    commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
      if (err || data.parameters === undefined) {
        return;
      }
      const pid = data.parameters['pid'] as number;
      const label = data.parameters['label'] as string;
      found.set(pid !== undefined ? pid : 0, label !== undefined && label.length > 0 ? label : '远程桌面');
    });
    await publishEvent(EVENT_PROBE);
    await sleep(waitMs);
  } catch (e) {
    const err = e as BusinessError;
    console.warn(`HMRDP 会话探测：探测失败 code=${err.code}`);
  } finally {
    if (subscriber !== undefined) {
      try {
        commonEventManager.unsubscribe(subscriber);
      } catch (e) {
      }
    }
  }
  const labels: string[] = [];
  found.forEach((label: string) => {
    labels.push(label);
  });
  console.info(`HMRDP 会话探测：收到 ${labels.length} 个应答 [${labels.join(', ')}]`);
  return labels;
}
