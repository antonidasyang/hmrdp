import { SymbolGlyphModifier } from '@kit.ArkUI';
import { EditPCPage } from './EditPCPage';
import { SessionPage } from './SessionPage';
import hmrdp from 'libhmrdp.so';

@Entry
@Component
struct Index {
  pathStack: NavPathStack = new NavPathStack();
  @State coreVersion: string = '';

  aboutToAppear(): void {
    this.coreVersion = hmrdp.getVersion();
  }

  @Builder
  routeMap(name: string) {
    if (name === 'edit') {
      EditPCPage()
    } else if (name === 'session') {
      SessionPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
        // 空状态占位：M3a 换成真实电脑卡片列表
        Column({ space: 12 }) {
          Text('还没有添加电脑')
            .fontSize(18)
            .fontColor($r('sys.color.font_secondary'))
          Text('点击右上角 + 添加一台 Windows 电脑')
            .fontSize(14)
            .fontColor($r('sys.color.font_tertiary'))
          Button('添加电脑')
            .margin({ top: 16 })
            .onClick(() => {
              this.pathStack.pushPathByName('edit', undefined);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Text(`内核: ${this.coreVersion}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ bottom: 8 })
      }
      .width('100%')
      .height('100%')
    }
    .title('电脑')
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .menus([
      {
        value: 'add',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
        action: () => {
          this.pathStack.pushPathByName('edit', undefined);
        }
      }
    ])
    .navDestination(this.routeMap)
    .mode(NavigationMode.Stack)
  }
}
