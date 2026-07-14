// 「每次询问」模式的凭据输入对话框
@CustomDialog
export struct PasswordDialog {
  controller: CustomDialogController;
  pcName: string = '';
  @State username: string = '';
  @State password: string = '';
  onConfirm: (username: string, password: string) => void = () => {
  };

  private submit(): void {
    if (this.username.trim().length === 0) {
      return;
    }
    this.controller.close();
    this.onConfirm(this.username.trim(), this.password);
  }

  build() {
    Column({ space: 16 }) {
      Text(`连接到 ${this.pcName}`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .alignSelf(ItemAlign.Start)
      TextInput({ placeholder: '用户名', text: this.username })
        .type(InputType.USER_NAME)
        .enterKeyType(EnterKeyType.Next)
        .onChange((v: string) => {
          this.username = v;
        })
      TextInput({ placeholder: '密码', text: this.password })
        .type(InputType.Password)
        .enterKeyType(EnterKeyType.Go)
        .onChange((v: string) => {
          this.password = v;
        })
        // 密码框回车（软键盘 Go / 物理回车）直接连接，不必点按钮
        .onSubmit(() => {
          this.submit();
        })
      Row({ space: 12 }) {
        Button('取消')
          .buttonStyle(ButtonStyleMode.NORMAL)
          .layoutWeight(1)
          .onClick(() => {
            this.controller.close();
          })
        Button('连接')
          .layoutWeight(1)
          .enabled(this.username.trim().length > 0)
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')
    }
    .padding(24)
  }
}
