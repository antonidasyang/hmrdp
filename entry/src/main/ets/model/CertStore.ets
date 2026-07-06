import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'hmrdp_certs';

/** 已信任服务器证书指纹（host:port -> fingerprint） */
export class CertStore {
  private static prefs(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: PREF_NAME });
  }

  static get(context: common.Context, host: string, port: number): string {
    return CertStore.prefs(context).getSync(`${host}:${port}`, '') as string;
  }

  static trust(context: common.Context, host: string, port: number, fingerprint: string): void {
    const p = CertStore.prefs(context);
    p.putSync(`${host}:${port}`, fingerprint);
    p.flush();
  }
}
