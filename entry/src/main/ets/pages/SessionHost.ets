import { SessionParams } from '../model/SessionParams';
import { SessionPage } from './SessionPage';

// 独立会话窗口(SessionAbility)的承载页：从 LocalStorage 取参数，铺满渲染会话。
@Entry
@Component
struct SessionHost {
  @LocalStorageProp('sessionEpoch') @Watch('onEpoch') epoch: number = 0;
  pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.pushSession();
  }

  onEpoch(): void {
    // 参数更新（同一窗口切换到另一台电脑）：重开会话
    this.pathStack.clear();
    this.pushSession();
  }

  private pushSession(): void {
    const storage = LocalStorage.getShared();
    const sp = storage ? storage.get<SessionParams>('sessionParams') : undefined;
    if (sp) {
      this.pathStack.pushPathByName('session', sp);
    }
  }

  @Builder
  routeMap(name: string) {
    if (name === 'session') {
      SessionPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
    }
    .hideNavBar(true)
    .navDestination(this.routeMap)
    .mode(NavigationMode.Stack)
  }
}
