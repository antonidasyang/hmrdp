import hmrdp from 'libhmrdp.so';

interface OssItem {
  name: string;
  license: string;
  url: string;
}

const OSS: OssItem[] = [
  { name: 'FreeRDP', license: 'Apache License 2.0', url: 'https://github.com/FreeRDP/FreeRDP' },
  { name: 'OpenSSL', license: 'Apache License 2.0', url: 'https://www.openssl.org/' },
  { name: 'zlib', license: 'zlib License', url: 'https://zlib.net/' },
];

@Component
export struct AboutPage {
  @State coreVersion: string = '';

  aboutToAppear(): void {
    this.coreVersion = hmrdp.getVersion();
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 6 }) {
            Text('HMRDP')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
            Text('OpenHarmony 远程桌面客户端')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
            Text('版本 1.0.0 · 内核 ' + this.coreVersion)
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 24, bottom: 8 })

          Column({ space: 8 }) {
            Text('版权')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .alignSelf(ItemAlign.Start)
            Text('Copyright © 2026 d2ssoft\n本软件以 Apache License 2.0 开源，免费提供。\n请仅连接你拥有或已获授权的计算机。')
              .fontSize(14)
              .alignSelf(ItemAlign.Start)
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          Column({ space: 12 }) {
            Text('开源许可')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .alignSelf(ItemAlign.Start)
            ForEach(OSS, (item: OssItem) => {
              Column({ space: 2 }) {
                Text(item.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)
                Text(item.license)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .alignSelf(ItemAlign.Start)
                Text(item.url)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_tertiary'))
                  .alignSelf(ItemAlign.Start)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (item: OssItem) => item.name)
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('sys.color.comp_background_list_card'))
        }
        .padding(16)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('关于')
  }
}
