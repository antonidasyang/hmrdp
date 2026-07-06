import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { PCEntry } from './PCEntry';

const PREF_NAME = 'hmrdp_pcs';
const KEY_LIST = 'pc_list';

function toBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function fromBytes(data: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(data);
}

function passwordAlias(id: string): string {
  return `hmrdp_pc_${id}`;
}

/** 电脑列表（Preferences）+ 密码（Asset Store 系统级加密）持久化 */
export class PCStore {
  private static prefs(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: PREF_NAME });
  }

  static load(context: common.Context): PCEntry[] {
    const p = PCStore.prefs(context);
    const raw = p.getSync(KEY_LIST, '[]') as string;
    try {
      return JSON.parse(raw) as PCEntry[];
    } catch (e) {
      return [];
    }
  }

  static saveAll(context: common.Context, list: PCEntry[]): void {
    const p = PCStore.prefs(context);
    p.putSync(KEY_LIST, JSON.stringify(list));
    p.flush();
  }

  static upsert(context: common.Context, entry: PCEntry): void {
    const list = PCStore.load(context);
    const idx = list.findIndex((it) => it.id === entry.id);
    if (idx >= 0) {
      list[idx] = entry;
    } else {
      list.push(entry);
    }
    PCStore.saveAll(context, list);
  }

  static remove(context: common.Context, id: string): void {
    const list = PCStore.load(context).filter((it) => it.id !== id);
    PCStore.saveAll(context, list);
  }

  static newId(): string {
    return util.generateRandomUUID(false);
  }

  // ---- 密码（Asset Store Kit）----

  static async savePassword(id: string, password: string): Promise<void> {
    const alias = passwordAlias(id);
    await PCStore.removePassword(id); // 幂等：先清旧值
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, toBytes(alias));
    attrs.set(asset.Tag.SECRET, toBytes(password));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
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
        throw new Error(`移除密码失败: ${err.code} ${err.message}`);
      }
    }
  }
}
