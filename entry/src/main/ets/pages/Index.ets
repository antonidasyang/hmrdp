import { SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { EditPCPage, EditPCParams } from './EditPCPage';
import { SessionPage } from './SessionPage';
import { SessionParams } from '../model/SessionParams';
import { PCEntry, displayName } from '../model/PCEntry';
import { PCStore } from '../model/PCStore';
import { PasswordDialog } from '../components/PasswordDialog';
import hmrdp from 'libhmrdp.so';

@Entry
@Component
struct Index {
  pathStack: NavPathStack = new NavPathStack();
  @State pcs: PCEntry[] = [];
  @State coreVersion: string = '';
  @StorageProp('pcsVersion') @Watch('reload') pcsVersion: number = 0;
  private askTarget: PCEntry | null = null;
  private dialogController: CustomDialogController = new CustomDialogController({
    builder: PasswordDialog({
      pcName: this.askTarget ? displayName(this.askTarget) : '',
      username: this.askTarget?.username ?? '',
      onConfirm: (username: string, password: string) => {
        this.startSession(this.askTarget!, username, password);
      }
    }),
    autoCancel: true
  });

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
  }

  aboutToAppear(): void {
    this.coreVersion = hmrdp.getVersion();
    this.reload();
  }

  reload(): void {
    this.pcs = PCStore.load(this.ctx());
  }

  private startSession(pc: PCEntry, username: string, password: string): void {
    pc.lastUsedAt = Date.now();
    PCStore.upsert(this.ctx(), pc);
    const params = new SessionParams(pc.host, pc.port, username, password, '');
    params.width = pc.width;
    params.height = pc.height;
    params.scale = pc.scale;
    this.pathStack.pushPathByName('session', params);
  }

  private connectTo(pc: PCEntry): void {
    if (pc.hasPassword && pc.username.length > 0) {
      PCStore.getPassword(pc.id).then((password: string | null) => {
        if (password !== null) {
          this.startSession(pc, pc.username, password);
        } else {
          this.askCredentials(pc);
        }
      });
    } else {
      this.askCredentials(pc);
    }
  }

  private askCredentials(pc: PCEntry): void {
    this.askTarget = pc;
    // 重建 controller 以刷新 builder 参数
    this.dialogController = new CustomDialogController({
      builder: PasswordDialog({
        pcName: displayName(pc),
        username: pc.username,
        onConfirm: (username: string, password: string) => {
          this.startSession(pc, username, password);
        }
      }),
      autoCancel: true
    });
    this.dialogController.open();
  }

  private removePC(pc: PCEntry): void {
    PCStore.remove(this.ctx(), pc.id);
    PCStore.removePassword(pc.id);
    this.reload();
  }

  @Builder
  routeMap(name: string) {
    if (name === 'edit') {
      EditPCPage()
    } else if (name === 'session') {
      SessionPage()
    }
  }

  @Builder
  cardMenu(pc: PCEntry) {
    Menu() {
      MenuItem({ content: '编辑' })
        .onClick(() => {
          this.pathStack.pushPathByName('edit', new EditPCParams(pc.id));
        })
      MenuItem({ content: '删除' })
        .onClick(() => {
          this.removePC(pc);
        })
    }
  }

  @Builder
  pcCard(pc: PCEntry) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.computer'))
          .fontSize(28)
          .fontColor(['#1E7FD9'])
      }
      .width(52)
      .height(52)
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#141E7FD9')

      Column({ space: 4 }) {
        Text(displayName(pc))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(pc.username.length > 0 ? `${pc.host} · ${pc.username}` : pc.host)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
      this.connectTo(pc);
    })
    .bindContextMenu(this.cardMenu(pc), ResponseType.LongPress)
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
        if (this.pcs.length === 0) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.computer'))
              .fontSize(64)
              .fontColor([$r('sys.color.font_tertiary')])
            Text('还没有添加电脑')
              .fontSize(18)
              .fontColor($r('sys.color.font_secondary'))
            Text('长按卡片可编辑或删除')
              .fontSize(13)
              .fontColor($r('sys.color.font_tertiary'))
            Button('添加电脑')
              .margin({ top: 16 })
              .onClick(() => {
                this.pathStack.pushPathByName('edit', new EditPCParams(''));
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.pcs, (pc: PCEntry) => {
              ListItem() {
                this.pcCard(pc)
              }
            }, (pc: PCEntry) => pc.id)
          }
          .padding({ left: 16, right: 16, top: 8 })
          .width('100%')
          .layoutWeight(1)
        }

        Text(`HMRDP · ${this.coreVersion}`)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ bottom: 6 })
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
          this.pathStack.pushPathByName('edit', new EditPCParams(''));
        }
      }
    ])
    .navDestination(this.routeMap)
    .mode(NavigationMode.Stack)
  }
}
