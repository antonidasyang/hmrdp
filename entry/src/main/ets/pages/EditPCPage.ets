@Component
export struct EditPCPage {
  @State hostname: string = '';
  @State friendlyName: string = '';

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        // M3a: 完整表单（账户、显示设置等）
        TextInput({ placeholder: '电脑名或 IP 地址（如 192.168.1.10:3389）' })
          .onChange((v: string) => {
            this.hostname = v;
          })
        TextInput({ placeholder: '友好名称（可选）' })
          .onChange((v: string) => {
            this.friendlyName = v;
          })
        Blank()
      }
      .padding(16)
      .width('100%')
      .height('100%')
    }
    .title('添加电脑')
  }
}
