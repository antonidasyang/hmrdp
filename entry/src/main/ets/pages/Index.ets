import { SymbolGlyphModifier, window, display } from '@kit.ArkUI';
import { common, Want, StartOptions, AbilityConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EditPCPage, EditPCParams } from './EditPCPage';
import { SessionPage } from './SessionPage';
import { AboutPage } from './AboutPage';
import { AccountsPage } from './AccountsPage';
import { EditAccountPage } from './EditAccountPage';
import { SettingsPage } from './SettingsPage';
import { SessionParams } from '../model/SessionParams';
import { PCEntry, displayName } from '../model/PCEntry';
import { PCStore } from '../model/PCStore';
import { AccountStore } from '../model/AccountStore';
import { DEFAULT_SHARE_DIR, shareLabel, ensureFilePermissions } from '../model/ShareFolders';
import { isPcDevice, isLargeScreen } from '../model/DeviceKit';
import { PasswordDialog } from '../components/PasswordDialog';
import hmrdp from 'libhmrdp.so';

@Entry
@Component
struct Index {
  pathStack: NavPathStack = new NavPathStack();
  @State pcs: PCEntry[] = [];
  @State coreVersion: string = '';
  @StorageProp('pcsVersion') @Watch('reload') pcsVersion: number = 0;
  // 会话页需全屏：大屏(分栏)时隐藏左侧列表栏
  @StorageProp('hmrdpInSession') inSession: boolean = false;
  private askTarget: PCEntry | null = null;
  private dialogController: CustomDialogController = new CustomDialogController({
    builder: PasswordDialog({
      pcName: this.askTarget ? displayName(this.askTarget) : '',
      username: this.askTarget?.username ?? '',
      onConfirm: (username: string, password: string) => {
        this.startSession(this.askTarget!, username, password, '');
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
    // 不在启动时申请文件权限：改为在用户选择共享文件夹/发起带共享会话的场景内申请
    this.applyPortrait();
    this.watchFoldStatus();
  }

  /** 列表页朝向：手机与折叠屏外屏竖屏；平板与折叠屏内屏（大屏形态）横屏。
   *  PC/2in1 是窗口化形态，不设朝向。会话页一律横屏，退出时自己按同一判据切回。 */
  private async applyPortrait(): Promise<void> {
    if (isPcDevice()) {
      return;
    }
    const large = isLargeScreen();
    try {
      const win = await window.getLastWindow(this.ctx());
      await win.setPreferredOrientation(large ? window.Orientation.AUTO_ROTATION_LANDSCAPE
                                             : window.Orientation.PORTRAIT);
      hilog.info(0x0000, 'Index', '列表页朝向: %{public}s', large ? '横屏(大屏形态)' : '竖屏');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, 'Index', '设置朝向失败: code=%{public}d', err.code);
    }
  }

  /** 折叠屏展开/合起时重新判定列表页朝向（内屏横、外屏竖） */
  private watchFoldStatus(): void {
    try {
      if (!display.isFoldable()) {
        return;
      }
      display.on('foldStatusChange', (status: display.FoldStatus) => {
        hilog.info(0x0000, 'Index', '折叠状态变化: %{public}d', status);
        if (!AppStorage.get<boolean>('hmrdpInSession')) {
          this.applyPortrait(); // 会话中不动（会话恒横屏），退出后由列表页重设
        }
      });
    } catch (e) {
      // 非折叠屏或接口不可用，忽略
    }
  }

  reload(): void {
    this.pcs = PCStore.load(this.ctx());
  }

  /** domain：关联账号的域（AccountEntry.domain）；手动凭据/无域时传空串 */
  private startSession(pc: PCEntry, username: string, password: string, domain: string): void {
    // 只记最近使用时间，不整对象回写：列表内存态可能滞后于刚做的编辑，
    // 整对象 upsert 会把磁盘上已保存的分辨率/账号/共享目录覆盖回去。
    PCStore.touch(this.ctx(), pc.id);
    const params = new SessionParams(pc.host, pc.port, username, password, domain);
    params.width = pc.width;
    params.height = pc.height;
    params.scale = pc.scale;
    params.fullscreen = pc.fullscreen === true;
    params.shareDir = pc.shareDir ?? DEFAULT_SHARE_DIR;
    const launch = () => {
      if (isPcDevice()) {
        this.launchSessionWindow(params); // PC：开独立全屏会话窗口
      } else {
        this.pathStack.pushPathByName('session', params); // 手机/平板：应用内会话
      }
    };
    // 本次会话将把本地共享目录挂给远程电脑 → 在此场景内申请目录权限（未授权则会话内回退沙箱）
    if (pc.shareDir !== undefined) {
      ensureFilePermissions(this.ctx() as common.UIAbilityContext).then(launch).catch(launch);
    } else {
      launch();
    }
  }

  /** PC/2in1：把会话开进单独的 UIAbility 窗口（与列表窗口分开） */
  private launchSessionWindow(params: SessionParams): void {
    const ctx = this.ctx() as common.UIAbilityContext;
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      moduleName: ctx.abilityInfo.moduleName,
      abilityName: 'SessionAbility',
      parameters: {
        host: params.host,
        port: params.port,
        username: params.username,
        password: params.password,
        domain: params.domain,
        width: params.width,
        height: params.height,
        scale: params.scale,
        fullscreen: params.fullscreen,
        shareDir: params.shareDir ? JSON.stringify(params.shareDir) : ''
      }
    };
    // 全屏窗口。进程与实例管理走 SessionAbility 的 specified+isolationProcess（见 AppStage）：
    // 每台电脑一个会话窗口+独立进程；再次连接同一台电脑时系统直接把已有窗口唤到前台，
    // 不再新建（此前 multiton+processMode 每次双击都开新窗口）。
    const options: StartOptions = {
      windowMode: AbilityConstant.WindowMode.WINDOW_MODE_FULLSCREEN
    };
    ctx.startAbility(want, options).catch((e: Object) => {
      // 启动独立窗口失败则回退到应用内会话
      this.pathStack.pushPathByName('session', params);
    });
  }

  private connectTo(pc: PCEntry): void {
    // 以磁盘最新值为准：ForEach 按id复用列表项时，点击闭包可能持有编辑前的旧对象，
    // 直接用会连到旧分辨率/旧账号。这里按id重新取一份最新的。
    const cur: PCEntry = PCStore.load(this.ctx()).find((it) => it.id === pc.id) ?? pc;
    const acctId: string = cur.accountId ?? '';
    // 凭据来源诊断（不打印密码本身）：弹密码框时用它区分「没关联账号」和「账号密码取不到」
    hilog.info(0x0000, 'Index', '连接 %{public}s: accountId=%{public}s 本机hasPassword=%{public}s 用户名=%{public}s',
      displayName(cur), acctId.length > 0 ? acctId : '(空)', `${cur.hasPassword}`,
      cur.username.length > 0 ? cur.username : '(空)');
    // 关联账号优先解析
    if (acctId.length > 0) {
      const acct = AccountStore.find(this.ctx(), acctId);
      hilog.info(0x0000, 'Index', '账号 %{public}s: 找到=%{public}s hasPassword=%{public}s 域=%{public}s',
        acctId, `${acct !== undefined}`, `${acct?.hasPassword}`,
        acct !== undefined && acct.domain.length > 0 ? acct.domain : '(无)');
      if (acct) {
        if (acct.hasPassword) {
          AccountStore.getPassword(acct.id).then((password: string | null) => {
            hilog.info(0x0000, 'Index', '账号密码查询结果=%{public}s',
              password !== null ? '取到' : 'null(加密库无记录)');
            if (password !== null) {
              this.startSession(cur, acct.username, password, acct.domain);
            } else {
              // 标志说已存但加密库查不到（记录丢失）→ 询问一次，确认后补存回账号自愈
              this.askCredentials(cur, acct.username, acct.domain, (u: string, p: string) => {
                if (u === acct.username && p.length > 0) {
                  AccountStore.savePassword(acct.id, p).catch((e: BusinessError) => {
                    hilog.warn(0x0000, 'Index', '补存账号密码失败: code=%{public}d', e.code);
                  });
                }
              });
            }
          });
        } else {
          // 账号没存密码：每次询问（密码统一在「账号」页维护，这里不回存）
          this.askCredentials(cur, acct.username, acct.domain);
        }
        return;
      }
      // 账号已被删除 → 退回本机凭据
    }
    if (cur.hasPassword && cur.username.length > 0) {
      PCStore.getPassword(cur.id).then((password: string | null) => {
        if (password !== null) {
          this.startSession(cur, cur.username, password, '');
        } else {
          // 标志说已存但加密库查不到（记录丢失）→ 询问一次，确认后补存自愈
          this.askCredentials(cur, cur.username, '', (u: string, p: string) => {
            if (u === cur.username && p.length > 0) {
              PCStore.savePassword(cur.id, p).catch((e: BusinessError) => {
                hilog.warn(0x0000, 'Index', '补存电脑密码失败: code=%{public}d', e.code);
              });
            }
          });
        }
      });
    } else {
      this.askCredentials(cur, cur.username, '');
    }
  }

  /** domain：关联账号的域，随本次会话一起用；restore：仅在「已保存的密码丢失」场景传入，
   *  确认后把输入的密码补存回加密库（账号本就没存密码的情况不回存） */
  private askCredentials(pc: PCEntry, username: string, domain: string,
    restore?: (u: string, p: string) => void): void {
    this.askTarget = pc;
    // 重建 controller 以刷新 builder 参数
    this.dialogController = new CustomDialogController({
      builder: PasswordDialog({
        pcName: displayName(pc),
        username: username,
        onConfirm: (u: string, password: string) => {
          if (restore !== undefined) {
            restore(u, password);
          }
          this.startSession(pc, u, password, domain);
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
    } else if (name === 'about') {
      AboutPage()
    } else if (name === 'accounts') {
      AccountsPage()
    } else if (name === 'editAccount') {
      EditAccountPage()
    } else if (name === 'settings') {
      SettingsPage()
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
    Row({ space: 16 }) {
      // 连接区（图标 + 友好名/地址）——点这里开始远控
      Row({ space: 16 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.computer'))
            .fontSize(38)
            .fontColor(['#1E7FD9'])
        }
        .width(64)
        .height(64)
        .borderRadius(16)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#141E7FD9')

        Column({ space: 5 }) {
          // 有友好名显示友好名，否则直接显示地址
          Text(displayName(pc))
            .fontSize(19)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(pc.username.length > 0 ? `${pc.host} · ${pc.username}` : pc.host)
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(13)
              .fontColor([$r('sys.color.font_secondary')])
            Text(shareLabel(pc.shareDir))
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .onClick(() => {
        this.connectTo(pc);
      })

      // 「更多」独立按钮：右侧单独触控区，弹出编辑/删除，不与连接区冲突
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(24)
          .fontColor([$r('sys.color.font_secondary')])
      }
      .width(48)
      .height(48)
      .backgroundColor(Color.Transparent)
      .bindMenu([
        {
          value: '编辑',
          action: () => {
            this.pathStack.pushPathByName('edit', new EditPCParams(pc.id));
          }
        },
        {
          value: '删除',
          action: () => {
            this.removePC(pc);
          }
        }
      ] as MenuElement[])
    }
    .width('100%')
    .padding({ left: 18, right: 10, top: 18, bottom: 18 })
    .borderRadius(18)
    .backgroundColor($r('sys.color.comp_background_list_card'))
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
          // 每台电脑独占一行的大卡片；大屏限宽居中，避免过宽
          Scroll() {
            Column() {
              Column({ space: 12 }) {
                // key 必须包含内容而不只是 id：ForEach 对 key 相同的项不重建，
                // 编辑保存后卡片会一直显示旧值（磁盘其实已存上）。内容进 key 才会刷新。
                ForEach(this.pcs, (pc: PCEntry) => {
                  this.pcCard(pc)
                }, (pc: PCEntry) => JSON.stringify(pc))
              }
              .width('100%')
              .constraintSize({ maxWidth: 840 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
        }

        Text(`RDP远程桌面 · ${this.coreVersion}`)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ bottom: 6 })
      }
      .width('100%')
      .height('100%')
    }
    .title('电脑')
    .titleMode(NavigationTitleMode.Mini)
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .menus([
      {
        value: '添加电脑',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
        action: () => {
          this.pathStack.pushPathByName('edit', new EditPCParams(''));
        }
      },
      {
        value: '账号',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.person_2')),
        action: () => {
          this.pathStack.pushPathByName('accounts', null);
        }
      },
      {
        value: '设置',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
        action: () => {
          this.pathStack.pushPathByName('settings', null);
        }
      },
      {
        value: '关于',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.info_circle')),
        action: () => {
          this.pathStack.pushPathByName('about', null);
        }
      }
    ])
    .navDestination(this.routeMap)
    .mode(NavigationMode.Stack)
    .hideNavBar(this.inSession)
  }
}
