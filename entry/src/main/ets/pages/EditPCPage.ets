import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PCEntry } from '../model/PCEntry';
import { PCStore } from '../model/PCStore';
import { AccountEntry, accountDisplay } from '../model/AccountEntry';
import { AccountStore } from '../model/AccountStore';
import { EditAccountParams } from './EditAccountPage';
import { ShareDir, DEFAULT_SHARE_DIR, shareLabel, ShareTarget, SHARE_TARGETS } from '../model/ShareFolders';
import { Environment } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';

export class EditPCParams {
  /** 空串 = 新建 */
  id: string = '';

  constructor(id: string) {
    this.id = id;
  }
}

interface ResolutionOption {
  label: string;
  width: number;
  height: number;
  fullscreen?: boolean;
}

const RESOLUTIONS: ResolutionOption[] = [
  { label: '跟随窗口（动态）', width: 0, height: 0 },
  { label: '全屏（跟随本机）', width: 0, height: 0, fullscreen: true },
  { label: '1280 × 720', width: 1280, height: 720 },
  { label: '1920 × 1080', width: 1920, height: 1080 },
  { label: '2560 × 1440', width: 2560, height: 1440 },
];

interface ScaleOption {
  label: string;
  value: number;
}

const SCALES: ScaleOption[] = [
  { label: '跟随设备', value: 0 },
  { label: '100%', value: 100 },
  { label: '150%', value: 150 },
  { label: '200%', value: 200 },
  { label: '300%', value: 300 },
];

@Component
export struct EditPCPage {
  @State hostname: string = '';
  @State friendlyName: string = '';
  @State username: string = '';
  @State password: string = '';
  @State hasSavedPassword: boolean = false;
  @State resolutionIndex: number = 0;
  @State scaleIndex: number = 0;
  @State editingId: string = '';
  @State shareDir: ShareDir | undefined = { base: DEFAULT_SHARE_DIR.base, sub: DEFAULT_SHARE_DIR.sub };
  @State accounts: AccountEntry[] = [];
  /** 选中的已保存账号 id；'' = 手动输入 */
  @State accountId: string = '';
  @StorageProp('accountsVersion') @Watch('reloadAccounts') accountsVersion: number = 0;
  private pathStack: NavPathStack | null = null;
  // 目录浏览器内联状态（不走 @CustomDialog，避免回调传不回来）
  @State fbVisible: boolean = false;
  @State fbBase: string = 'download';
  @State fbSub: string = '';
  @State fbEntries: string[] = [];
  @State fbLoading: boolean = false;
  @State fbError: string = '';

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
  }

  // 打开目录浏览器：从当前 shareDir 初始化
  private openFolderPicker(): void {
    this.fbBase = this.shareDir?.base ?? DEFAULT_SHARE_DIR.base;
    this.fbSub = this.shareDir?.sub ?? DEFAULT_SHARE_DIR.sub;
    this.fbVisible = true;
    this.fbRefresh();
  }

  private fbBasePath(): string | undefined {
    try {
      if (this.fbBase === 'download') {
        return Environment.getUserDownloadDir();
      }
      if (this.fbBase === 'documents') {
        return Environment.getUserDocumentDir();
      }
      if (this.fbBase === 'desktop') {
        return Environment.getUserDesktopDir();
      }
    } catch (e) {
      return undefined;
    }
    return undefined;
  }

  private async fbRefresh(): Promise<void> {
    this.fbError = '';
    const b = this.fbBasePath();
    if (!b) {
      this.fbEntries = [];
      this.fbError = '无访问权限（未授权该目录）';
      return;
    }
    const p = this.fbSub.length > 0 ? `${b}/${this.fbSub}` : b;
    this.fbLoading = true;
    try {
      const names: string[] = await fs.listFile(p);
      const dirs: string[] = [];
      for (const n of names) {
        try {
          const s = await fs.stat(`${p}/${n}`);
          if (s.isDirectory()) {
            dirs.push(n);
          }
        } catch (e) {
        }
      }
      dirs.sort();
      this.fbEntries = dirs;
    } catch (e) {
      this.fbEntries = [];
      this.fbError = '无法读取目录';
    } finally {
      this.fbLoading = false;
    }
  }

  private fbEnter(name: string): void {
    this.fbSub = this.fbSub.length > 0 ? `${this.fbSub}/${name}` : name;
    this.fbRefresh();
  }

  private fbUp(): void {
    if (this.fbSub.length === 0) {
      return;
    }
    const idx = this.fbSub.lastIndexOf('/');
    this.fbSub = idx >= 0 ? this.fbSub.substring(0, idx) : '';
    this.fbRefresh();
  }

  private fbSwitchBase(key: string): void {
    this.fbBase = key;
    this.fbSub = '';
    this.fbRefresh();
  }

  private fbConfirm(): void {
    this.shareDir = { base: this.fbBase, sub: this.fbSub };
    this.fbVisible = false;
  }

  private fbClear(): void {
    this.shareDir = undefined;
    this.fbVisible = false;
  }

  reloadAccounts(): void {
    this.accounts = AccountStore.load(this.ctx());
    // 关联的账号若被删除则退回手动
    if (this.accountId.length > 0 && !this.accounts.some((a) => a.id === this.accountId)) {
      this.accountId = '';
    }
  }

  /** Select 选中项：0 = 手动输入，i+1 = accounts[i] */
  private accountSelIndex(): number {
    if (this.accountId.length === 0) {
      return 0;
    }
    const i = this.accounts.findIndex((a) => a.id === this.accountId);
    return i < 0 ? 0 : i + 1;
  }

  private accountSelLabel(): string {
    const idx = this.accountSelIndex();
    if (idx === 0) {
      return '手动输入';
    }
    return accountDisplay(this.accounts[idx - 1]);
  }

  private accountOptions(): SelectOption[] {
    const opts: SelectOption[] = [{ value: '手动输入' }];
    for (const a of this.accounts) {
      opts.push({ value: accountDisplay(a) });
    }
    return opts;
  }

  private loadForEdit(id: string): void {
    const pc = PCStore.load(this.ctx()).find((it) => it.id === id);
    if (!pc) {
      return;
    }
    this.editingId = pc.id;
    this.friendlyName = pc.name;
    this.hostname = pc.port === 3389 ? pc.host : `${pc.host}:${pc.port}`;
    this.username = pc.username;
    this.hasSavedPassword = pc.hasPassword;
    if (pc.hasPassword) {
      // 标志可能失真（加密库记录丢失但 hasPassword 还是 true）：真查一次，
      // 否则界面显示「密码已保存」，用户留空保存等于什么都没存
      PCStore.getPassword(pc.id).then((p: string | null) => {
        if (p === null) {
          this.hasSavedPassword = false;
          promptAction.showToast({ message: '之前保存的密码已失效，请重新输入' });
        }
      });
    }
    this.accountId = pc.accountId ?? '';
    this.shareDir = pc.shareDir ? { base: pc.shareDir.base, sub: pc.shareDir.sub } :
      { base: DEFAULT_SHARE_DIR.base, sub: DEFAULT_SHARE_DIR.sub };
    const pcFull = pc.fullscreen === true;
    this.resolutionIndex = Math.max(0, RESOLUTIONS.findIndex((r) =>
      r.width === pc.width && r.height === pc.height && (r.fullscreen === true) === pcFull));
    this.scaleIndex = Math.max(0, SCALES.findIndex((s) => s.value === pc.scale));
  }

  private parseHost(): string[] | null {
    let host = this.hostname.trim();
    let port = 3389;
    const idx = host.lastIndexOf(':');
    if (idx > 0 && host.indexOf(':') === idx) { // 排除 IPv6 裸地址
      const p = Number.parseInt(host.substring(idx + 1));
      if (!Number.isNaN(p) && p > 0 && p < 65536) {
        port = p;
        host = host.substring(0, idx);
      }
    }
    if (host.length === 0) {
      return null;
    }
    return [host, `${port}`];
  }

  private async save(): Promise<void> {
    const parsed = this.parseHost();
    if (parsed === null) {
      promptAction.showToast({ message: '请输入电脑名或 IP 地址' });
      return;
    }
    const id = this.editingId.length > 0 ? this.editingId : PCStore.newId();
    const old = PCStore.load(this.ctx()).find((it) => it.id === id);

    const useAccount = this.accountId.length > 0;
    const account = useAccount ? this.accounts.find((a) => a.id === this.accountId) : undefined;

    let username = this.username.trim();
    let hasPassword = this.hasSavedPassword;
    if (useAccount && account) {
      // 账号提供凭据：用户名取账号（冗余存一份便于列表显示），本机不再单独存密码
      username = account.username;
      hasPassword = false;
    } else if (this.password.length > 0) {
      try {
        await PCStore.savePassword(id, this.password);
        hasPassword = true;
      } catch (e) {
        // 失败必须出声并留在编辑页：静默失败会让用户以为已保存
        const err = e as BusinessError;
        promptAction.showToast({ message: `密码保存失败（错误码 ${err.code}），请重试` });
        return;
      }
    }

    const entry: PCEntry = {
      id: id,
      name: this.friendlyName.trim(),
      host: parsed[0],
      port: Number.parseInt(parsed[1]),
      username: username,
      hasPassword: hasPassword,
      accountId: useAccount ? this.accountId : undefined,
      width: RESOLUTIONS[this.resolutionIndex].width,
      height: RESOLUTIONS[this.resolutionIndex].height,
      scale: SCALES[this.scaleIndex].value,
      fullscreen: RESOLUTIONS[this.resolutionIndex].fullscreen === true,
      shareDir: this.shareDir,
      createdAt: old?.createdAt ?? Date.now(),
      lastUsedAt: old?.lastUsedAt ?? 0
    };
    PCStore.upsert(this.ctx(), entry);
    AppStorage.setOrCreate('pcsVersion', Date.now());
    this.pathStack?.pop();
  }

  private async clearPassword(): Promise<void> {
    if (this.editingId.length > 0) {
      await PCStore.removePassword(this.editingId);
      const pc = PCStore.load(this.ctx()).find((it) => it.id === this.editingId);
      if (pc) {
        pc.hasPassword = false;
        PCStore.upsert(this.ctx(), pc);
      }
    }
    this.hasSavedPassword = false;
    this.password = '';
    promptAction.showToast({ message: '已清除保存的密码' });
  }

  private removeAndBack(): void {
    if (this.editingId.length > 0) {
      PCStore.remove(this.ctx(), this.editingId);
      PCStore.removePassword(this.editingId);
      AppStorage.setOrCreate('pcsVersion', Date.now());
    }
    this.pathStack?.pop();
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('sys.color.font_secondary'))
      .alignSelf(ItemAlign.Start)
      .margin({ top: 8 })
  }

  @Builder
  shareFolderRow() {
    Row() {
      Column({ space: 4 }) {
        Text('共享文件夹')
          .fontSize(15)
        Text(shareLabel(this.shareDir))
          .fontSize(12)
          .fontColor('#888888')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('更改')
        .fontSize(14)
        .fontColor('#4DA3FF')
    }
    .width('100%')
    .height(56)
    .padding({ left: 0, right: 0 })
    .onClick(() => this.openFolderPicker())
  }

  // 目录浏览器 overlay（内联，不走 @CustomDialog）
  @Builder
  folderPickerOverlay() {
    Column() {
      Column({ space: 10 }) {
        Row({ space: 6 }) {
          ForEach(SHARE_TARGETS, (t: ShareTarget) => {
            Button(t.label)
              .fontSize(13)
              .height(32)
              .backgroundColor(this.fbBase === t.key ? '#4DA3FF' : '#EEEEEE')
              .fontColor(this.fbBase === t.key ? Color.White : '#333333')
              .onClick(() => this.fbSwitchBase(t.key))
          }, (t: ShareTarget) => t.key)
        }
        .width('100%')

        Text(`当前位置：${SHARE_TARGETS.find((x) => x.key === this.fbBase)?.label ?? this.fbBase}${this.fbSub.length > 0 ? ' > ' + this.fbSub : ''}`)
          .fontSize(13)
          .fontColor('#666666')
          .maxLines(2)
          .width('100%')

        Row({ space: 8 }) {
          Button('上一级')
            .fontSize(13)
            .height(30)
            .enabled(this.fbSub.length > 0)
            .onClick(() => this.fbUp())
          Blank()
          Text(this.fbLoading ? '读取中…' : `${this.fbEntries.length} 个子文件夹`)
            .fontSize(12)
            .fontColor('#999999')
        }
        .width('100%')

        if (this.fbError.length > 0) {
          Text(this.fbError)
            .fontSize(14)
            .fontColor('#E05555')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(20)
        } else if (this.fbLoading) {
          LoadingProgress().width(36).height(36)
        } else if (this.fbEntries.length === 0) {
          Text('（无子文件夹）')
            .fontSize(14)
            .fontColor('#999999')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(20)
        } else {
          Scroll() {
            Column({ space: 0 }) {
              ForEach(this.fbEntries, (name: string) => {
                Row() {
                  SymbolGlyph($r('sys.symbol.folder'))
                    .fontSize(18)
                    .fontColor(['#F0A030'])
                  Text(name)
                    .fontSize(15)
                    .margin({ left: 8 })
                  Blank()
                  Text('›')
                    .fontSize(18)
                    .fontColor('#CCCCCC')
                }
                .width('100%')
                .height(44)
                .padding({ left: 8, right: 12 })
                .onClick(() => this.fbEnter(name))
              }, (name: string) => name)
            }
          }
          .layoutWeight(1)
          .align(Alignment.Top)
        }

        Row({ space: 12 }) {
          Button('不共享')
            .layoutWeight(1)
            .backgroundColor('#F2F2F2')
            .fontColor('#333333')
            .onClick(() => this.fbClear())
          Button('选择当前目录')
            .layoutWeight(1)
            .onClick(() => this.fbConfirm())
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('88%')
      .height('68%')
      .padding(16)
      .backgroundColor(Color.White)
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Stack() {
      Scroll() {
        Column({ space: 12 }) {
          this.sectionTitle('电脑')
          TextInput({ placeholder: '电脑名或 IP 地址（如 192.168.1.10:3389）', text: this.hostname })
            .onChange((v: string) => {
              this.hostname = v;
            })
          TextInput({ placeholder: '友好名称（可选）', text: this.friendlyName })
            .onChange((v: string) => {
              this.friendlyName = v;
            })

          this.sectionTitle('用户账户')
          Row() {
            Text('账号')
              .fontSize(15)
            Blank()
            Select(this.accountOptions())
              .selected(this.accountSelIndex())
              .value(this.accountSelLabel())
              .onSelect((index: number) => {
                this.accountId = index === 0 ? '' : this.accounts[index - 1].id;
              })
          }
          .width('100%')

          if (this.accountId.length === 0) {
            TextInput({ placeholder: '用户名（如 Administrator 或 user@domain）', text: this.username })
              .type(InputType.USER_NAME)
              .onChange((v: string) => {
                this.username = v;
              })
            TextInput({
              placeholder: this.hasSavedPassword ? '密码已保存（留空保持不变）' : '密码（可选，保存在系统加密存储）',
              text: this.password
            })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.password = v;
              })
            if (this.hasSavedPassword) {
              Button('清除已保存的密码')
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .fontColor($r('sys.color.warning'))
                .onClick(() => {
                  this.clearPassword();
                })
            }
            Text('留空则连接时询问')
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
              .alignSelf(ItemAlign.Start)
          } else {
            Text(`将使用账号「${this.accountSelLabel()}」的用户名与密码`)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .alignSelf(ItemAlign.Start)
              .margin({ top: 4 })
          }
          Button('＋ 新建账号')
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .alignSelf(ItemAlign.Start)
            .onClick(() => {
              this.pathStack?.pushPathByName('editAccount', new EditAccountParams(''));
            })

          this.sectionTitle('显示')
          Row() {
            Text('分辨率')
              .fontSize(15)
            Blank()
            Select(RESOLUTIONS.map((r): SelectOption => ({ value: r.label })))
              .selected(this.resolutionIndex)
              .value(RESOLUTIONS[this.resolutionIndex].label)
              .onSelect((index: number) => {
                this.resolutionIndex = index;
              })
          }
          .width('100%')

          Row() {
            Text('显示缩放')
              .fontSize(15)
            Blank()
            Select(SCALES.map((s): SelectOption => ({ value: s.label })))
              .selected(this.scaleIndex)
              .value(SCALES[this.scaleIndex].label)
              .onSelect((index: number) => {
                this.scaleIndex = index;
              })
          }
          .width('100%')

          this.sectionTitle('共享文件夹（挂到远程电脑，需允许文件访问）')
          this.shareFolderRow()

          Button('保存')
            .width('100%')
            .margin({ top: 20 })
            .enabled(this.hostname.trim().length > 0)
            .onClick(() => {
              this.save();
            })

          if (this.editingId.length > 0) {
            Button('删除这台电脑')
              .width('100%')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .fontColor($r('sys.color.warning'))
              .onClick(() => {
                this.removeAndBack();
              })
          }
        }
        .padding(16)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      if (this.fbVisible) {
        this.folderPickerOverlay()
      }
      }
    }
    .title(this.editingId.length > 0 ? '编辑电脑' : '添加电脑')
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
      this.reloadAccounts();
      if (ctx.pathInfo.param instanceof EditPCParams) {
        const params = ctx.pathInfo.param as EditPCParams;
        if (params.id.length > 0) {
          this.loadForEdit(params.id);
        }
      }
    })
  }
}
