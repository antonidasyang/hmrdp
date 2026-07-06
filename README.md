# HMRDP

OpenHarmony / HarmonyOS 上的开源远程桌面（RDP）客户端，用于远程控制 Windows 电脑。
交互对标 iOS/Android 上的 Microsoft Windows App，但只保留最简单的「添加电脑」直连模式，
不含工作区/云桌面等企业功能。

- 协议内核：[FreeRDP 3.x](https://github.com/FreeRDP/FreeRDP)（交叉编译为 OHOS native 库）
- UI：ArkTS / ArkUI，会话画面走 XComponent
- 图形：RDP Graphics Pipeline（AVC420/H.264），通过系统 AVCodec 硬解
- 凭据：Asset Store Kit 系统级加密存储
- 许可证：[Apache License 2.0](LICENSE)

## 功能

- 添加/编辑/删除电脑（主机、端口、友好名称、账户、显示设置）
- NLA/CredSSP 认证，TLS 加密，自签证书首次信任
- 触摸直控 / 触控板两种操作模式，双指捏合缩放
- 软键盘与物理键鼠输入
- 断线自动重连

## 目录结构

```
AppScope/            应用级配置（bundleName: com.d2ssoft.hmrdp）
entry/               主模块（ArkTS UI + native NAPI 桥接）
  src/main/ets/      页面与业务逻辑
  src/main/cpp/      NAPI 桥接层与 FreeRDP 会话核心
third_party/         三方库交叉编译脚本与补丁（源码与产物不入库）
docs/                文档（隐私政策、上架材料等）
```

## 构建

依赖：macOS/Linux + DevEco Studio（含 OpenHarmony native SDK）+ cmake + ninja。

```bash
# 1. 交叉编译三方库（OpenSSL、FreeRDP），产物输出到 third_party/prebuilt/
cd third_party && ./build_all.sh

# 2. 构建 HAP（或直接用 DevEco Studio 打开工程）
./hvigorw assembleHap --mode module -p product=default
```

真机安装与被控端（Windows）配置见 [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)。

## 版权与第三方声明

Copyright 2026 d2ssoft。本项目以 Apache License 2.0 开源，详见 [LICENSE](LICENSE) 与
[NOTICE](NOTICE)。捆绑的第三方组件清单见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 免责声明

被控端需为支持远程桌面服务的 Windows 版本（专业版/企业版等；家庭版不含 RDP 服务端）。
请仅连接你拥有或已获授权的计算机。
