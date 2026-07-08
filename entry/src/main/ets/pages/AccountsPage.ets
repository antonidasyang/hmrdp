import { SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AccountEntry, accountDisplay } from '../model/AccountEntry';
import { AccountStore } from '../model/AccountStore';
import { EditAccountParams } from './EditAccountPage';

@Component
export struct AccountsPage {
  @State accounts: AccountEntry[] = [];
  @StorageProp('accountsVersion') @Watch('reload') accountsVersion: number = 0;
  private pathStack: NavPathStack | null = null;

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
  }

  reload(): void {
    this.accounts = AccountStore.load(this.ctx());
  }

  @Builder
  accountRow(a: AccountEntry) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(24)
          .fontColor(['#1E7FD9'])
      }
      .width(48)
      .height(48)
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#141E7FD9')

      Column({ space: 4 }) {
        Text(accountDisplay(a))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(a.hasPassword ? '已保存密码' : '未保存密码')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .onClick(() => {
      this.pathStack?.pushPathByName('editAccount', new EditAccountParams(a.id));
    })
  }

  build() {
    NavDestination() {
      Column() {
        if (this.accounts.length === 0) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.person'))
              .fontSize(64)
              .fontColor([$r('sys.color.font_tertiary')])
            Text('还没有账号')
              .fontSize(18)
              .fontColor($r('sys.color.font_secondary'))
            Text('保存常用账号后，添加电脑时可直接选用')
              .fontSize(13)
              .fontColor($r('sys.color.font_tertiary'))
            Button('添加账号')
              .margin({ top: 16 })
              .onClick(() => {
                this.pathStack?.pushPathByName('editAccount', new EditAccountParams(''));
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 10 }) {
              ForEach(this.accounts, (a: AccountEntry) => {
                this.accountRow(a)
              }, (a: AccountEntry) => a.id)
            }
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('账号')
    .menus([
      {
        value: 'add',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
        action: () => {
          this.pathStack?.pushPathByName('editAccount', new EditAccountParams(''));
        }
      }
    ])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
      this.reload();
    })
  }
}
