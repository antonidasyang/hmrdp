// 会话内的紧凑软键盘（自绘）+ 可独立使用的导航键面板。
//
// 为什么不用系统输入法：客户端侧 @ohos.inputMethod 没有任何控制键盘尺寸/位置的接口，
// resize/moveTo/adjustPanelRect 都在 @ohos.inputMethodEngine（输入法应用自己用）里。
// 小艺键盘在横屏下占 222vp，接近屏幕高度的一半，远端画面只剩 40%。自绘才能做到
// 「键矮、字母区靠左、右侧空出来的地方放 Esc/方向键/PgUp 这些功能键」。
//
// 所有键一律走扫描码（不是 Unicode），所以 Ctrl+C / Shift+方向键这类组合天然可用；
// 中文输入交给系统输入法，此时左侧字母区让位，右侧导航面板（NavPad）继续留在屏幕上。

/** 紧凑键盘总高（vp）。系统键盘 222vp，这里 156vp */
export const SOFT_KB_H = 156;
/** 导航面板高度（vp），4 行 */
export const NAV_PAD_H = 150;

/** 修饰键位掩码，与 SessionPage 的 stickyMods 同一套（MOD_KEYS 下标） */
const KMOD_CTRL = 1;
const KMOD_ALT = 2;
const KMOD_SHIFT = 4;
const KMOD_WIN = 8;

const R_NORMAL = 0;
const R_MOD = 1;
const R_ACT = 2;

/** 键盘自身的动作，不发给远端 */
const ACT_LAYER = 1; // 字母层 <-> 数字符号层
const ACT_FN = 2;    // 右侧导航区 <-> F1-F12
export const ACT_IME = 3;  // 切到系统输入法（输中文）
export const ACT_HIDE = 4; // 收起键盘

interface KeyDef {
  label: string;
  /** Shift 按下时的显示；空串表示与 label 相同 */
  shiftLabel: string;
  /** PS/2 set 1 扫描码 */
  code: number;
  /** 扩展键（E0 前缀） */
  ext: boolean;
  /** 发送时自动补一个 Shift（符号层的 { } | ~ _ + 这类直给键） */
  needShift: boolean;
  /** 同一行内的横向宽度权重 */
  weight: number;
  role: number;
  modBit: number;
  act: number;
}

/** 一行键 + 两侧缩进（vp），用来做 QWERTY 第二行的半键错位 */
interface KbRow {
  keys: KeyDef[];
  indent: number;
}

function k(label: string, code: number, shiftLabel: string = '', weight: number = 1): KeyDef {
  return {
    label: label, shiftLabel: shiftLabel, code: code, ext: false, needShift: false,
    weight: weight, role: R_NORMAL, modBit: 0, act: 0
  };
}

/** 扩展键（方向键/Home/End/PgUp/PgDn/Del/Ins/Win） */
function ke(label: string, code: number, weight: number = 1): KeyDef {
  return {
    label: label, shiftLabel: '', code: code, ext: true, needShift: false,
    weight: weight, role: R_NORMAL, modBit: 0, act: 0
  };
}

/** 本身就是 Shift 变体的符号，发送时自动补 Shift */
function ksh(label: string, code: number): KeyDef {
  return {
    label: label, shiftLabel: '', code: code, ext: false, needShift: true,
    weight: 1, role: R_NORMAL, modBit: 0, act: 0
  };
}

function kmod(label: string, bit: number, code: number, ext: boolean, weight: number): KeyDef {
  return {
    label: label, shiftLabel: '', code: code, ext: ext, needShift: false,
    weight: weight, role: R_MOD, modBit: bit, act: 0
  };
}

function kact(label: string, act: number, weight: number): KeyDef {
  return {
    label: label, shiftLabel: '', code: 0, ext: false, needShift: false,
    weight: weight, role: R_ACT, modBit: 0, act: act
  };
}

const K_SHIFT: KeyDef = kmod('⇧', KMOD_SHIFT, 0x2A, false, 1.5);
const K_BACKSPACE: KeyDef = k('⌫', 0x0E, '', 1.5);

// ---- 左侧：字母层 ----

const ROW_QWERTY: KeyDef[] = [
  k('q', 0x10, 'Q'), k('w', 0x11, 'W'), k('e', 0x12, 'E'), k('r', 0x13, 'R'), k('t', 0x14, 'T'),
  k('y', 0x15, 'Y'), k('u', 0x16, 'U'), k('i', 0x17, 'I'), k('o', 0x18, 'O'), k('p', 0x19, 'P')
];
const ROW_ASDF: KeyDef[] = [
  k('a', 0x1E, 'A'), k('s', 0x1F, 'S'), k('d', 0x20, 'D'), k('f', 0x21, 'F'), k('g', 0x22, 'G'),
  k('h', 0x23, 'H'), k('j', 0x24, 'J'), k('k', 0x25, 'K'), k('l', 0x26, 'L')
];
const ROW_ZXCV: KeyDef[] = [K_SHIFT,
  k('z', 0x2C, 'Z'), k('x', 0x2D, 'X'), k('c', 0x2E, 'C'), k('v', 0x2F, 'V'),
  k('b', 0x30, 'B'), k('n', 0x31, 'N'), k('m', 0x32, 'M'),
  K_BACKSPACE];

// ---- 左侧：数字/符号层 ----

const ROW_NUM: KeyDef[] = [
  k('1', 0x02, '!'), k('2', 0x03, '@'), k('3', 0x04, '#'), k('4', 0x05, '$'), k('5', 0x06, '%'),
  k('6', 0x07, '^'), k('7', 0x08, '&'), k('8', 0x09, '*'), k('9', 0x0A, '('), k('0', 0x0B, ')')
];
const ROW_SYM1: KeyDef[] = [
  k('-', 0x0C, '_'), k('=', 0x0D, '+'), k('[', 0x1A, '{'), k(']', 0x1B, '}'), k('\\', 0x2B, '|'),
  k(';', 0x27, ':'), k('\'', 0x28, '"'), k(',', 0x33, '<'), k('.', 0x34, '>'), k('/', 0x35, '?')
];
// 常用的 Shift 变体直接给键位，省得先按 Shift 再按键
const ROW_SYM2: KeyDef[] = [K_SHIFT,
  k('`', 0x29, '~'), ksh('{', 0x1A), ksh('}', 0x1B), ksh('|', 0x2B),
  ksh('~', 0x29), ksh('_', 0x0C), ksh('+', 0x0D),
  K_BACKSPACE];

const ROW_BOTTOM: KeyDef[] = [
  kact('?123', ACT_LAYER, 1.4),
  kact('中', ACT_IME, 1),
  kmod('Ctrl', KMOD_CTRL, 0x1D, false, 1.2),
  kmod('Alt', KMOD_ALT, 0x38, false, 1.2),
  kmod('Win', KMOD_WIN, 0x5B, true, 1.2),
  k(' ', 0x39, '', 3),
  kact('Fn', ACT_FN, 1.1),
  k('↵', 0x1C, '', 1.6)
];

const ALPHA_ROWS: KbRow[] = [
  { keys: ROW_QWERTY, indent: 0 },
  { keys: ROW_ASDF, indent: 26 }, // 比上一行少一键，两侧各缩半个键宽，保住 QWERTY 手感
  { keys: ROW_ZXCV, indent: 0 },
  { keys: ROW_BOTTOM, indent: 0 }
];
const SYMBOL_ROWS: KbRow[] = [
  { keys: ROW_NUM, indent: 0 },
  { keys: ROW_SYM1, indent: 0 },
  { keys: ROW_SYM2, indent: 0 },
  { keys: ROW_BOTTOM, indent: 0 }
];

// ---- 右侧导航面板：4 行。↑ 在 ↓ 正上方，保持倒 T 手感 ----

const NAV_ROWS: KeyDef[][] = [
  [ke('Esc', 0x01), ke('Del', 0x53), ke('Ins', 0x52)],
  [ke('Home', 0x47), ke('↑', 0x48), ke('PgUp', 0x49)],
  [ke('←', 0x4B), ke('↓', 0x50), ke('→', 0x4D)],
  [k('Tab', 0x0F), ke('End', 0x4F), ke('PgDn', 0x51)]
];

const FN_ROWS: KeyDef[][] = [
  [k('F1', 0x3B), k('F2', 0x3C), k('F3', 0x3D)],
  [k('F4', 0x3E), k('F5', 0x3F), k('F6', 0x40)],
  [k('F7', 0x41), k('F8', 0x42), k('F9', 0x43)],
  [k('F10', 0x44), k('F11', 0x57), k('F12', 0x58)]
];

/** 独立使用（打中文时）才需要的修饰键列——紧凑键盘自己的底行已经有它们了 */
const MOD_COL: KeyDef[] = [
  kmod('Ctrl', KMOD_CTRL, 0x1D, false, 1),
  kmod('Alt', KMOD_ALT, 0x38, false, 1),
  K_SHIFT,
  kmod('Win', KMOD_WIN, 0x5B, true, 1)
];

/** 导航面板宽度：带修饰键列时 4 列，否则 3 列 */
export function navPadWidth(withMods: boolean): number {
  return withMods ? 222 : 168;
}

@Component
export struct NavPad {
  @Link stickyMods: number;
  /** 显示 F1-F12 而不是导航键 */
  @Prop fnLayer: boolean = false;
  /** 最左边补一列 Ctrl/Alt/Shift/Win（脱离紧凑键盘单独用时需要） */
  @Prop withMods: boolean = false;
  /** 面板高度；放进紧凑键盘时由外部给出可用高度 */
  @Prop padHeight: number = NAV_PAD_H;
  onKey: (code: number, ext: boolean, needShift: boolean) => void = () => {};

  private isActive(key: KeyDef): boolean {
    return key.role === R_MOD && (this.stickyMods & key.modBit) !== 0;
  }

  private tap(key: KeyDef): void {
    if (key.role === R_MOD) {
      this.stickyMods = this.stickyMods ^ key.modBit;
      return;
    }
    this.onKey(key.code, key.ext, key.needShift);
  }

  build() {
    Row({ space: 4 }) {
      if (this.withMods) {
        Column({ space: 4 }) {
          ForEach(MOD_COL, (item: KeyDef) => {
            Row() {
              Text(item.label)
                .fontSize(item.label.length > 2 ? 11 : 15)
                .fontColor(this.isActive(item) ? '#111111' : Color.White)
                .maxLines(1)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .borderRadius(5)
            .backgroundColor(this.isActive(item) ? '#4DA3FF' : '#26FFFFFF')
            .onClick(() => { this.tap(item); })
            // key 带上点亮态：同 key 的项不会重新执行 itemGenerator，点了不会变色
          }, (item: KeyDef) => `${item.label}${this.isActive(item) ? 1 : 0}`)
        }
        .width(50)
        .height('100%')
      }
      Column({ space: 4 }) {
        ForEach(this.fnLayer ? FN_ROWS : NAV_ROWS, (row: KeyDef[]) => {
          Row({ space: 4 }) {
            ForEach(row, (item: KeyDef) => {
              Row() {
                Text(item.label)
                  .fontSize(item.label.length > 2 ? 11 : 15)
                  .fontColor(Color.White)
                  .maxLines(1)
              }
              .layoutWeight(1)
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .borderRadius(5)
              .backgroundColor('#40FFFFFF')
              .onClick(() => { this.tap(item); })
            }, (item: KeyDef) => item.label)
          }
          .width('100%')
          .layoutWeight(1)
        }, (row: KeyDef[], idx: number) => `${this.fnLayer ? 'f' : 'n'}${idx}`)
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width(navPadWidth(this.withMods))
    .height(this.padHeight)
  }
}

@Component
export struct SoftKeyboard {
  /** 粘滞修饰键，与会话页共享 */
  @Link stickyMods: number;
  /** false = 字母层，true = 数字/符号层 */
  @State symbolLayer: boolean = false;
  /** 右侧区显示 F1-F12 */
  @State fnLayer: boolean = false;
  onKey: (code: number, ext: boolean, needShift: boolean) => void = () => {};
  /** 键盘自身动作（切系统输入法 / 收起） */
  onAction: (act: number) => void = () => {};

  private shiftOn(): boolean {
    return (this.stickyMods & KMOD_SHIFT) !== 0;
  }

  private tap(key: KeyDef): void {
    if (key.role === R_MOD) {
      this.stickyMods = this.stickyMods ^ key.modBit; // 再点一次取消
      return;
    }
    if (key.role === R_ACT) {
      if (key.act === ACT_LAYER) {
        this.symbolLayer = !this.symbolLayer;
      } else if (key.act === ACT_FN) {
        this.fnLayer = !this.fnLayer;
      } else {
        this.onAction(key.act);
      }
      return;
    }
    this.onKey(key.code, key.ext, key.needShift);
  }

  private caption(key: KeyDef): string {
    if (key.role === R_ACT && key.act === ACT_LAYER) {
      return this.symbolLayer ? 'ABC' : '?123';
    }
    if (key.shiftLabel.length > 0 && this.shiftOn()) {
      return key.shiftLabel;
    }
    return key.label;
  }

  private isActive(key: KeyDef): boolean {
    if (key.role === R_MOD) {
      return (this.stickyMods & key.modBit) !== 0;
    }
    if (key.role === R_ACT && key.act === ACT_FN) {
      return this.fnLayer;
    }
    return false;
  }

  build() {
    Row({ space: 6 }) {
      // 左：字母/符号区。整个键盘的行都在这一个 ForEach 里渲染，且 key 带上层标记——
      // 不能把行数据当参数传给 @Builder：ArkUI V1 的 @Builder 值参不响应变化，
      // ?123 切到符号层时参数变了但 Builder 不重渲染，键盘会一直停在字母层。
      Column({ space: 4 }) {
        ForEach(this.symbolLayer ? SYMBOL_ROWS : ALPHA_ROWS, (row: KbRow) => {
          Row({ space: 4 }) {
            ForEach(row.keys, (item: KeyDef) => {
              Row() {
                Text(this.caption(item))
                  .fontSize(this.caption(item).length > 2 ? 11 : 15)
                  .fontColor(this.isActive(item) ? '#111111' : Color.White)
                  .maxLines(1)
              }
              .layoutWeight(item.weight)
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .borderRadius(5)
              .backgroundColor(this.isActive(item) ? '#4DA3FF'
                : (item.role === R_NORMAL ? '#40FFFFFF' : '#26FFFFFF'))
              .onClick(() => { this.tap(item); })
              // key 带上显示文字与点亮态，Shift 切大小写、修饰键点亮才会真的重画
            }, (item: KeyDef) => `${item.label}|${this.caption(item)}|${this.isActive(item) ? 1 : 0}`)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: row.indent, right: row.indent })
        }, (row: KbRow, idx: number) => `${this.symbolLayer ? 's' : 'a'}${idx}`)
      }
      .layoutWeight(1)
      .height('100%')

      NavPad({
        stickyMods: $stickyMods,
        fnLayer: this.fnLayer,
        withMods: false,
        padHeight: SOFT_KB_H - 10,
        onKey: this.onKey
      })
    }
    .width('100%')
    .height(SOFT_KB_H)
    .padding({ left: 6, right: 6, top: 5, bottom: 5 })
    .backgroundColor('#F0181818')
  }
}
