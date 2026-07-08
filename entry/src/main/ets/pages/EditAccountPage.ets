import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AccountEntry } from '../model/AccountEntry';
import { AccountStore } from '../model/AccountStore';

export class EditAccountParams {
  /** 空串 = 新建 */
  id: string = '';

  constructor(id: string) {
    this.id = id;
  }
}

@Component
export struct EditAccountPage {
  @State label: string = '';
  @State username: string = '';
  @State domain: string = '';
  @State password: string = '';
  @State hasSavedPassword: boolean = false;
  @State editingId: string = '';
  private pathStack: NavPathStack | null = null;

  private ctx(): common.Context {
    return this.getUIContext().getHostContext()!;
  }

  private loadForEdit(id: string): void {
    const a = AccountStore.find(this.ctx(), id);
    if (!a) {
      return;
    }
    this.editingId = a.id;
    this.label = a.label;
    this.username = a.username;
    this.domain = a.domain;
    this.hasSavedPassword = a.hasPassword;
  }

  private async save(): Promise<void> {
    if (this.username.trim().length === 0) {
      promptAction.showToast({ message: '请输入用户名' });
      return;
    }
    const id = this.editingId.length > 0 ? this.editingId : AccountStore.newId();

    let hasPassword = this.hasSavedPassword;
    if (this.password.length > 0) {
      await AccountStore.savePassword(id, this.password);
      hasPassword = true;
    }

    const entry: AccountEntry = {
      id: id,
      label: this.label.trim(),
      username: this.username.trim(),
      domain: this.domain.trim(),
      hasPassword: hasPassword
    };
    AccountStore.upsert(this.ctx(), entry);
    AppStorage.setOrCreate('accountsVersion', Date.now());
    this.pathStack?.pop();
  }

  private async clearPassword(): Promise<void> {
    if (this.editingId.length > 0) {
      await AccountStore.removePassword(this.editingId);
      const a = AccountStore.find(this.ctx(), this.editingId);
      if (a) {
        a.hasPassword = false;
        AccountStore.upsert(this.ctx(), a);
      }
    }
    this.hasSavedPassword = false;
    this.password = '';
    promptAction.showToast({ message: '已清除保存的密码' });
  }

  private removeAndBack(): void {
    if (this.editingId.length > 0) {
      AccountStore.remove(this.ctx(), this.editingId);
      AccountStore.removePassword(this.editingId);
      AppStorage.setOrCreate('accountsVersion', Date.now());
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
          this.sectionTitle('账号信息')
          TextInput({ placeholder: '备注名（可选，如「公司 AD」）', text: this.label })
            .onChange((v: string) => {
              this.label = v;
            })
          TextInput({ placeholder: '用户名（如 Administrator）', text: this.username })
            .type(InputType.USER_NAME)
            .onChange((v: string) => {
              this.username = v;
            })
          TextInput({ placeholder: '域（可选，如 CORP）', text: this.domain })
            .onChange((v: string) => {
              this.domain = v;
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

          Button('保存')
            .width('100%')
            .margin({ top: 20 })
            .enabled(this.username.trim().length > 0)
            .onClick(() => {
              this.save();
            })

          if (this.editingId.length > 0) {
            Button('删除这个账号')
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
    .title(this.editingId.length > 0 ? '编辑账号' : '添加账号')
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
      if (ctx.pathInfo.param instanceof EditAccountParams) {
        const params = ctx.pathInfo.param as EditAccountParams;
        if (params.id.length > 0) {
          this.loadForEdit(params.id);
        }
      }
    })
  }
}
