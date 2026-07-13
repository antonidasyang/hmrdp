import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountEntry } from './AccountEntry';

const PREF_NAME = 'hmrdp_accounts';
const KEY_LIST = 'account_list';

function toBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function fromBytes(data: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(data);
}

function passwordAlias(id: string): string {
  return `hmrdp_acct_${id}`;
}

/** 可复用账号列表（Preferences）+ 密码（Asset Store 系统级加密）持久化 */
export class AccountStore {
  private static prefs(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: PREF_NAME });
  }

  static load(context: common.Context): AccountEntry[] {
    const raw = AccountStore.prefs(context).getSync(KEY_LIST, '[]') as string;
    try {
      return JSON.parse(raw) as AccountEntry[];
    } catch (e) {
      return [];
    }
  }

  static find(context: common.Context, id: string): AccountEntry | undefined {
    return AccountStore.load(context).find((it) => it.id === id);
  }

  static saveAll(context: common.Context, list: AccountEntry[]): void {
    const p = AccountStore.prefs(context);
    p.putSync(KEY_LIST, JSON.stringify(list));
    p.flush();
  }

  static upsert(context: common.Context, entry: AccountEntry): void {
    const list = AccountStore.load(context);
    const idx = list.findIndex((it) => it.id === entry.id);
    if (idx >= 0) {
      list[idx] = entry;
    } else {
      list.push(entry);
    }
    AccountStore.saveAll(context, list);
  }

  static remove(context: common.Context, id: string): void {
    const list = AccountStore.load(context).filter((it) => it.id !== id);
    AccountStore.saveAll(context, list);
  }

  static newId(): string {
    return util.generateRandomUUID(false);
  }

  // ---- 密码（Asset Store Kit）----

  static async savePassword(id: string, password: string): Promise<void> {
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, toBytes(passwordAlias(id)));
    attrs.set(asset.Tag.SECRET, toBytes(password));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    // 已存在则原子覆盖。不能先 remove 再 add：add 失败会连旧密码一起丢，
    // 而列表里 hasPassword 仍是 true，之后每次连接都弹密码框。
    attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attrs);
  }

  static async getPassword(id: string): Promise<string | null> {
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, toBytes(passwordAlias(id)));
    attrs.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result = await asset.query(attrs);
      if (result.length === 0) {
        return null;
      }
      const secret = result[0].get(asset.Tag.SECRET) as Uint8Array;
      return fromBytes(secret);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, 'AccountStore', '查询账号密码失败: code=%{public}d', err.code);
      return null;
    }
  }

  static async removePassword(id: string): Promise<void> {
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, toBytes(passwordAlias(id)));
    try {
      await asset.remove(attrs);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== asset.ErrorCode.NOT_FOUND) {
        throw new Error(`移除账号密码失败: ${err.code} ${err.message}`);
      }
    }
  }
}
