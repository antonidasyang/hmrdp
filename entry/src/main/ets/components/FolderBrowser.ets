import fs from '@ohos.file.fs';
import { Environment } from '@kit.CoreFileKit';
import { ShareDir, ShareTarget, SHARE_TARGETS } from '../model/ShareFolders';

// 共享文件夹选择器：在 下载/文档/桌面 三棵树内浏览子目录，挑一个作为共享盘根。
// 这些目录有真实路径（已声明权限），drive addin 可直接挂；桌面权限 system_basic 需 ACL，
// 未授权时该 base 读不出目录，浏览器会提示。
@CustomDialog
export struct FolderBrowser {
  controller: CustomDialogController;
  init: ShareDir = { base: 'download', sub: '' };
  onConfirm: (d: ShareDir | undefined) => void = () => {};
  @State base: string = 'download';
  @State sub: string = '';
  @State entries: string[] = [];
  @State loading: boolean = false;
  @State errorText: string = '';

  aboutToAppear(): void {
    this.base = this.init.base;
    this.sub = this.init.sub;
    this.refresh();
  }

  private basePath(): string | undefined {
    try {
      if (this.base === 'download') {
        return Environment.getUserDownloadDir();
      }
      if (this.base === 'documents') {
        return Environment.getUserDocumentDir();
      }
      if (this.base === 'desktop') {
        return Environment.getUserDesktopDir();
      }
    } catch (e) {
      return undefined;
    }
    return undefined;
  }

  private baseLabel(): string {
    const t = SHARE_TARGETS.find((x) => x.key === this.base);
    return t ? t.label : this.base;
  }

  private async refresh(): Promise<void> {
    this.errorText = '';
    const b = this.basePath();
    if (!b) {
      this.entries = [];
      this.errorText = '无访问权限（未授权该目录）';
      return;
    }
    const p = this.sub.length > 0 ? `${b}/${this.sub}` : b;
    this.loading = true;
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
          // 跳过无法 stat 的项
        }
      }
      dirs.sort();
      this.entries = dirs;
    } catch (e) {
      this.entries = [];
      this.errorText = '无法读取目录';
    } finally {
      this.loading = false;
    }
  }

  private enter(name: string): void {
    this.sub = this.sub.length > 0 ? `${this.sub}/${name}` : name;
    this.refresh();
  }

  private up(): void {
    if (this.sub.length === 0) {
      return;
    }
    const idx = this.sub.lastIndexOf('/');
    this.sub = idx >= 0 ? this.sub.substring(0, idx) : '';
    this.refresh();
  }

  private switchBase(key: string): void {
    this.base = key;
    this.sub = '';
    this.refresh();
  }

  private confirm(): void {
    this.onConfirm({ base: this.base, sub: this.sub });
    this.controller.close();
  }

  private clear(): void {
    this.onConfirm(undefined);
    this.controller.close();
  }

  build() {
    Column({ space: 10 }) {
      // base 切换
      Row({ space: 6 }) {
        ForEach(SHARE_TARGETS, (t: ShareTarget) => {
          Button(t.label)
            .fontSize(13)
            .height(32)
            .backgroundColor(this.base === t.key ? '#4DA3FF' : '#EEEEEE')
            .fontColor(this.base === t.key ? Color.White : '#333333')
            .onClick(() => this.switchBase(t.key))
        }, (t: ShareTarget) => t.key)
      }
      .width('100%')

      // 面包屑
      Text(`当前位置：${this.baseLabel()}${this.sub.length > 0 ? ' > ' + this.sub : ''}`)
        .fontSize(13)
        .fontColor('#666666')
        .maxLines(2)
        .width('100%')

      // 上一级
      Row({ space: 8 }) {
        Button('上一级')
          .fontSize(13)
          .height(30)
          .enabled(this.sub.length > 0)
          .onClick(() => this.up())
        Blank()
        Text(this.loading ? '读取中…' : `${this.entries.length} 个子文件夹`)
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')

      // 列表
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(14)
          .fontColor('#E05555')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(20)
      } else if (this.loading) {
        LoadingProgress().width(36).height(36)
      } else if (this.entries.length === 0) {
        Text('（无子文件夹）')
          .fontSize(14)
          .fontColor('#999999')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(20)
      } else {
        Scroll() {
          Column({ space: 0 }) {
            ForEach(this.entries, (name: string) => {
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
              .onClick(() => this.enter(name))
            }, (name: string) => name)
          }
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }

      // 底部
      Row({ space: 12 }) {
        Button('不共享')
          .layoutWeight(1)
          .backgroundColor('#F2F2F2')
          .fontColor('#333333')
          .onClick(() => this.clear())
        Button('选择当前目录')
          .layoutWeight(1)
          .onClick(() => this.confirm())
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
}
