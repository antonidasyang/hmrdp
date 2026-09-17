// 会话内的紧凑软键盘（自绘）。
//
// 为什么不用系统输入法：客户端侧 @ohos.inputMethod 没有任何控制键盘尺寸/位置的接口，
// resize/moveTo/adjustPanelRect 都在 @ohos.inputMethodEngine（输入法应用自己用）里。
// 小艺键盘在横屏下占 222vp，接近屏幕高度的一半，远端画面只剩 40%。自绘才能做到
// 「键矮、字母区靠左、右侧空出来的地方放 Esc/方向键/PgUp 这些功能键」。
//
// 所有键一律走扫描码（不是 Unicode），所以 Ctrl+C / Shift+方向键这类组合天然可用；
// 中文输入仍交给系统输入法，键盘上的「中」键一键切过去。

/** 键盘总高（vp）。系统键盘 222 + 功能键条 34 = 256vp，这里 156vp，省出 100vp */
export const SOFT_KB_H = 156;

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

// ---- 左侧：字母 / 数字符号区，4 行 ----

const ROW_QWERTY: KeyDef[] = [
  k('q', 0x10, 'Q'), k('w', 0x11, 'W'), k('e', 0x12, 'E'), k('r', 0x13, 'R'), k('t', 0x14, 'T'),
  k('y', 0x15, 'Y'), k('u', 0x16, 'U'), k('i', 0x17, 'I'), k('o', 0x18, 'O'), k('p', 0x19, 'P')
];
const ROW_ASDF: KeyDef[] = [
  k('a', 0x1E, 'A'), k('s', 0x1F, 'S'), k('d', 0x20, 'D'), k('f', 0x21, 'F'), k('g', 0x22, 'G'),
  k('h', 0x23, 'H'), k('j', 0x24, 'J'), k('k', 0x25, 'K'), k('l', 0x26, 'L')
];
const ROW_ZXCV: KeyDef[] = [
  k('z', 0x2C, 'Z'), k('x', 0x2D, 'X'), k('c', 0x2E, 'C'), k('v', 0x2F, 'V'),
  k('b', 0x30, 'B'), k('n', 0x31, 'N'), k('m', 0x32, 'M')
];

const ROW_NUM: KeyDef[] = [
  k('1', 0x02, '!'), k('2', 0x03, '@'), k('3', 0x04, '#'), k('4', 0x05, '$'), k('5', 0x06, '%'),
  k('6', 0x07, '^'), k('7', 0x08, '&'), k('8', 0x09, '*'), k('9', 0x0A, '('), k('0', 0x0B, ')')
];
const ROW_SYM1: KeyDef[] = [
  k('-', 0x0C, '_'), k('=', 0x0D, '+'), k('[', 0x1A, '{'), k(']', 0x1B, '}'), k('\\', 0x2B, '|'),
  k(';', 0x27, ':'), k('\'', 0x28, '"'), k(',', 0x33, '<'), k('.', 0x34, '>'), k('/', 0x35, '?')
];
// 常用的 Shift 变体直接给键位，省得先按 Shift 再按键
const ROW_SYM2: KeyDef[] = [
  k('`', 0x29, '~'), ksh('{', 0x1A), ksh('}', 0x1B), ksh('|', 0x2B),
  ksh('~', 0x29), ksh('_', 0x0C), ksh('+', 0x0D)
];

const K_SHIFT: KeyDef = kmod('⇧', KMOD_SHIFT, 0x2A, false, 1.5);
const K_BACKSPACE: KeyDef = k('⌫', 0x0E, '', 1.5);

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

// ---- 右侧：导航键 / F 区，4 行 3 列。↑ 在 ↓ 正上方，保持倒 T 手感 ----

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

@Component
export struct SoftKeyboard {
  /** 粘滞修饰键，与会话页共享（功能键条与本键盘同一套状态） */
  @Link stickyMods: number;
  /** false = 字母层，true = 数字/符号层 */
  @State symbolLayer: boolean = false;
  /** 右侧区显示 F1-F12 */
  @State fnLayer: boolean = false;
  /** 发一个键（由会话页带上粘滞修饰键后下发） */
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

  /** ForEach 的 key 必须带上会影响显示的全部状态：同 key 的项不会重新执行
   *  itemGenerator，修饰键点了不会变色、Shift 后字母也不会变大写 */
  private keyId(key: KeyDef): string {
    return `${key.label}|${this.caption(key)}|${this.isActive(key) ? 1 : 0}`;
  }

  /** 单个键帽。内联而不是抽成 @Component：layoutWeight 必须落在父 Row 的直接子节点上，
   *  自定义组件外面那层包装会把权重吃掉，键宽就全乱了 */
  @Builder
  cap(key: KeyDef) {
    Row() {
      Text(this.caption(key))
        .fontSize(this.caption(key).length > 2 ? 11 : 15)
        .fontColor(this.isActive(key) ? '#111111' : Color.White)
        .maxLines(1)
    }
    .layoutWeight(key.weight)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .borderRadius(5)
    .backgroundColor(this.isActive(key) ? '#4DA3FF'
      : (key.role === R_NORMAL ? '#40FFFFFF' : '#26FFFFFF'))
    .onClick(() => { this.tap(key); })
  }

  /** indent：行两侧缩进（vp），用来做 QWERTY 第二行的半键错位 */
  @Builder
  keyRow(keys: KeyDef[], indent: number) {
    Row({ space: 4 }) {
      ForEach(keys, (item: KeyDef) => {
        this.cap(item)
      }, (item: KeyDef) => this.keyId(item))
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: indent, right: indent })
  }

  /** 第三行：⇧ + 中间键 + ⌫ */
  @Builder
  shiftRow(middle: KeyDef[]) {
    Row({ space: 4 }) {
      this.cap(K_SHIFT)
      ForEach(middle, (item: KeyDef) => {
        this.cap(item)
      }, (item: KeyDef) => this.keyId(item))
      this.cap(K_BACKSPACE)
    }
    .width('100%')
    .layoutWeight(1)
  }

  build() {
    Row({ space: 6 }) {
      // 左：字母/符号区，占满剩余宽度
      Column({ space: 4 }) {
        this.keyRow(this.symbolLayer ? ROW_NUM : ROW_QWERTY, 0)
        // 字母层第二行比第一行少一个键，两侧各缩进半个键宽；符号层是满 10 键，不缩
        this.keyRow(this.symbolLayer ? ROW_SYM1 : ROW_ASDF, this.symbolLayer ? 0 : 26)
        this.shiftRow(this.symbolLayer ? ROW_SYM2 : ROW_ZXCV)
        this.keyRow(ROW_BOTTOM, 0)
      }
      .layoutWeight(1)
      .height('100%')

      // 右：导航键 / F 区
      Column({ space: 4 }) {
        ForEach(this.fnLayer ? FN_ROWS : NAV_ROWS, (row: KeyDef[]) => {
          this.keyRow(row, 0)
        }, (row: KeyDef[], idx: number) => `${this.fnLayer ? 'f' : 'n'}${idx}`)
      }
      .width(168)
      .height('100%')
    }
    .width('100%')
    .height(SOFT_KB_H)
    .padding({ left: 6, right: 6, top: 5, bottom: 5 })
    .backgroundColor('#F0181818')
  }
}
