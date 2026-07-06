@Component
export struct SessionPage {
  build() {
    NavDestination() {
      Column() {
        // M2b: XComponent 远端桌面画面
        Text('会话页（施工中）')
          .fontColor(Color.White)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
  }
}
