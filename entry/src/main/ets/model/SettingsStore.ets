import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';

const PREF_NAME = 'hmrdp_settings';
const KEY_DESKTOP_HOTKEY = 'desktop_hotkey';

/** 修饰键位掩码，与原生 setDesktopHotkey 的约定一致（不含 Win：鸿蒙优先抢占，且会话中要转发给远端） */
export const MOD_CTRL = 1;
export const MOD_ALT = 2;
export const MOD_SHIFT = 4;

/** 返回鸿蒙桌面热键：PC 全屏会话里本地消费的组合键，触发即最小化回鸿蒙桌面。
 *  keyCode 用 OHOS 键码（KeyCode 枚举值），原生侧按同一套值匹配。 */
export interface DesktopHotkey {
  enabled: boolean;
  /** 位掩码：1=Ctrl 2=Alt 4=Shift；0 = 未配置 */
  mods: number;
  /** 触发键的 OHOS 键码；0 = 未配置 */
  keyCode: number;
}

/** 默认 Ctrl + Shift + Backspace：远端 Windows 基本不占用这个组合 */
export function defaultDesktopHotkey(): DesktopHotkey {
  return { enabled: true, mods: MOD_CTRL | MOD_SHIFT, keyCode: KeyCode.KEYCODE_DEL };
}

/** 修饰键本身不能作为触发键 */
export function isModifierKey(code: number): boolean {
  return code === KeyCode.KEYCODE_CTRL_LEFT || code === KeyCode.KEYCODE_CTRL_RIGHT ||
    code === KeyCode.KEYCODE_ALT_LEFT || code === KeyCode.KEYCODE_ALT_RIGHT ||
    code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT ||
    code === KeyCode.KEYCODE_META_LEFT || code === KeyCode.KEYCODE_META_RIGHT;
}

interface NamedKey {
  code: number;
  label: string;
}

const NAMED_KEYS: NamedKey[] = [
  { code: KeyCode.KEYCODE_DEL, label: 'Backspace' },
  { code: KeyCode.KEYCODE_FORWARD_DEL, label: 'Delete' },
  { code: KeyCode.KEYCODE_ENTER, label: 'Enter' },
  { code: KeyCode.KEYCODE_ESCAPE, label: 'Esc' },
  { code: KeyCode.KEYCODE_TAB, label: 'Tab' },
  { code: KeyCode.KEYCODE_SPACE, label: 'Space' },
  { code: KeyCode.KEYCODE_MOVE_HOME, label: 'Home' },
  { code: KeyCode.KEYCODE_MOVE_END, label: 'End' },
  { code: KeyCode.KEYCODE_PAGE_UP, label: 'PageUp' },
  { code: KeyCode.KEYCODE_PAGE_DOWN, label: 'PageDown' },
  { code: KeyCode.KEYCODE_INSERT, label: 'Insert' },
  { code: KeyCode.KEYCODE_DPAD_UP, label: '↑' },
  { code: KeyCode.KEYCODE_DPAD_DOWN, label: '↓' },
  { code: KeyCode.KEYCODE_DPAD_LEFT, label: '←' },
  { code: KeyCode.KEYCODE_DPAD_RIGHT, label: '→' },
  { code: KeyCode.KEYCODE_GRAVE, label: '`' },
  { code: KeyCode.KEYCODE_MINUS, label: '-' },
  { code: KeyCode.KEYCODE_EQUALS, label: '=' },
  { code: KeyCode.KEYCODE_LEFT_BRACKET, label: '[' },
  { code: KeyCode.KEYCODE_RIGHT_BRACKET, label: ']' },
  { code: KeyCode.KEYCODE_BACKSLASH, label: '\\' },
  { code: KeyCode.KEYCODE_SEMICOLON, label: ';' },
  { code: KeyCode.KEYCODE_APOSTROPHE, label: '\'' },
  { code: KeyCode.KEYCODE_COMMA, label: ',' },
  { code: KeyCode.KEYCODE_PERIOD, label: '.' },
  { code: KeyCode.KEYCODE_SLASH, label: '/' }
];

/** 键码 -> 显示名。字母/数字/F 键按区间算，其余查表；未知键退回「键码 NNNN」 */
export function keyLabel(code: number): string {
  if (code >= KeyCode.KEYCODE_A && code <= KeyCode.KEYCODE_Z) {
    return String.fromCharCode(65 + (code - KeyCode.KEYCODE_A));
  }
  if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) {
    return `${code - KeyCode.KEYCODE_0}`;
  }
  if (code >= KeyCode.KEYCODE_F1 && code <= KeyCode.KEYCODE_F12) {
    return `F${code - KeyCode.KEYCODE_F1 + 1}`;
  }
  const named = NAMED_KEYS.find((k) => k.code === code);
  return named !== undefined ? named.label : `键码 ${code}`;
}

/** 组合键显示名，如「Ctrl + Shift + Backspace」；未配置返回空串 */
export function hotkeyLabel(hk: DesktopHotkey): string {
  if (hk.mods === 0 || hk.keyCode === 0) {
    return '';
  }
  const parts: string[] = [];
  if ((hk.mods & MOD_CTRL) !== 0) {
    parts.push('Ctrl');
  }
  if ((hk.mods & MOD_ALT) !== 0) {
    parts.push('Alt');
  }
  if ((hk.mods & MOD_SHIFT) !== 0) {
    parts.push('Shift');
  }
  parts.push(keyLabel(hk.keyCode));
  return parts.join(' + ');
}

export interface HotkeyPreset {
  mods: number;
  keyCode: number;
}

/** 常用组合，供设置页下拉直选（键盘录入不可用时的兜底路径）。都避开了远端 Windows 常用键 */
export const HOTKEY_PRESETS: HotkeyPreset[] = [
  { mods: MOD_CTRL | MOD_SHIFT, keyCode: KeyCode.KEYCODE_DEL },
  { mods: MOD_CTRL | MOD_ALT, keyCode: KeyCode.KEYCODE_Q },
  { mods: MOD_CTRL | MOD_ALT, keyCode: KeyCode.KEYCODE_ENTER },
  { mods: MOD_CTRL | MOD_ALT, keyCode: KeyCode.KEYCODE_MOVE_HOME },
  { mods: MOD_CTRL | MOD_ALT, keyCode: KeyCode.KEYCODE_MOVE_END },
  { mods: MOD_CTRL | MOD_SHIFT, keyCode: KeyCode.KEYCODE_F12 }
];

/** 全局设置（Preferences）。会话页在连接成功/窗口重新聚焦时读一次并下发给原生。 */
export class SettingsStore {
  private static prefs(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: PREF_NAME });
  }

  static loadDesktopHotkey(context: common.Context): DesktopHotkey {
    const raw = SettingsStore.prefs(context).getSync(KEY_DESKTOP_HOTKEY, '') as string;
    if (raw.length === 0) {
      return defaultDesktopHotkey();
    }
    try {
      const hk = JSON.parse(raw) as DesktopHotkey;
      // 存量数据兜底：字段缺失或触发键非法时退回默认，避免下发一个永不命中的热键
      if (hk.keyCode === undefined || hk.mods === undefined || hk.keyCode === 0 || hk.mods === 0 ||
        isModifierKey(hk.keyCode)) {
        const def = defaultDesktopHotkey();
        def.enabled = hk.enabled !== false;
        return def;
      }
      return { enabled: hk.enabled !== false, mods: hk.mods, keyCode: hk.keyCode };
    } catch (e) {
      return defaultDesktopHotkey();
    }
  }

  static saveDesktopHotkey(context: common.Context, hk: DesktopHotkey): void {
    const p = SettingsStore.prefs(context);
    p.putSync(KEY_DESKTOP_HOTKEY, JSON.stringify(hk));
    p.flush();
  }
}
