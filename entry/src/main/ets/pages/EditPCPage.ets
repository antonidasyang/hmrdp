import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PCEntry } from '../model/PCEntry';
import { PCStore } from '../model/PCStore';
import { AccountEntry, accountDisplay } from '../model/AccountEntry';
import { AccountStore } from '../model/AccountStore';
import { EditAccountParams } from './EditAccountPage';

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
  @State accounts: AccountEntry[] = [];
  /** 选中的已保存账号 id；'' = 手动输入 */
  @State accountId: string = '';
  @StorageProp('accountsVersion') @Watch('reloadAccounts') accountsVersion: number = 0;
  private pathStack: NavPathStack | null = null;

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
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
    this.accountId = pc.accountId ?? '';
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
      await PCStore.savePassword(id, this.password);
      hasPassword = true;
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

  build() {
    NavDestination() {
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
