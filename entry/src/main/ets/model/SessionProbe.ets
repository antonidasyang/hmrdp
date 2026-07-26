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
    // 不能写成 parameters: params —— params 为 undefined 时「键存在但值是 undefined」，
    // ArkTS 参数校验直接抛 401（实测日志：探测失败 code=401）。分开构造。
    const options: commonEventManager.CommonEventPublishData = params !== undefined
      ? { bundleName: APP_BUNDLE, parameters: params }
      : { bundleName: APP_BUNDLE };
    try {
      commonEventManager.publish(event, options, (err: BusinessError) => {
        if (err) {
          console.warn(`HMRDP 会话探测：发布 ${event} 回调报错 code=${err.code}`);
        }
        resolve();
      });
    } catch (e) {
      // publish 对非法参数是同步抛，必须接住，否则上层 await 直接失败、连等待都不做
      const err = e as BusinessError;
      console.warn(`HMRDP 会话探测：发布 ${event} 抛异常 code=${err.code} msg=${err.message}`);
      resolve();
    }
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
            console.warn(`HMRDP 会话探测：接收探测报错 code=${err.code}`);
            return;
          }
          const params: Record<string, Object> = {
            'pid': process.pid as Object,
            'label': this.label as Object
          };
          console.info(`HMRDP 会话探测：收到探测，应答 pid=${process.pid} label=${this.label}`);
          publishEvent(EVENT_ALIVE, params);
        });
        console.info(`HMRDP 会话探测：已订阅存活探测 pid=${process.pid}`);
      })
      .catch((e: BusinessError) => {
        console.warn(`HMRDP 会话探测：订阅探测失败 code=${e.code} msg=${e.message}`);
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
  // 每一步单独接异常并各记一条日志：出问题时能直接看出卡在创建订阅者、订阅还是发布
  try {
    subscriber = await commonEventManager.createSubscriber({ events: [EVENT_ALIVE] });
  } catch (e) {
    const err = e as BusinessError;
    console.warn(`HMRDP 会话探测：创建订阅者失败 code=${err.code} msg=${err.message}`);
  }
  if (subscriber !== undefined) {
    try {
      commonEventManager.subscribe(subscriber,
        (err: BusinessError, data: commonEventManager.CommonEventData) => {
          if (err) {
            console.warn(`HMRDP 会话探测：接收应答报错 code=${err.code}`);
            return;
          }
          const params = data.parameters;
          const pid = params !== undefined ? params['pid'] as number : 0;
          const label = params !== undefined ? params['label'] as string : '';
          console.info(`HMRDP 会话探测：收到应答 pid=${pid} label=${label}`);
          found.set(pid !== undefined ? pid : 0, label !== undefined && label.length > 0 ? label : '远程桌面');
        });
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HMRDP 会话探测：订阅失败 code=${err.code} msg=${err.message}`);
    }
  }
  await publishEvent(EVENT_PROBE);
  await sleep(waitMs);
  if (subscriber !== undefined) {
    try {
      commonEventManager.unsubscribe(subscriber);
    } catch (e) {
    }
  }
  const labels: string[] = [];
  found.forEach((label: string) => {
    labels.push(label);
  });
  console.info(`HMRDP 会话探测：收到 ${labels.length} 个应答 [${labels.join(', ')}]`);
  return labels;
}
