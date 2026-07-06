# 构建、安装与使用

## 一、构建

### 环境
- macOS 或 Linux
- DevEco Studio（自带 OpenHarmony native SDK、node、JBR、hvigor）
- cmake、ninja（三方库交叉编译用；macOS 可 `brew install cmake ninja`）

### 步骤
```bash
# 1) 交叉编译三方库（OpenSSL、FreeRDP -> third_party/prebuilt/arm64-v8a）
cd third_party && ./build_all.sh && cd ..

# 2) 构建 HAP（命令行，使用 DevEco 自带工具链）
scripts/build_hap.sh            # debug，未签名
scripts/build_hap.sh release    # release，未签名
```
或直接用 DevEco Studio 打开工程构建。

未签名产物：
`entry/build/default/outputs/default/entry-default-unsigned.hap`

## 二、签名与安装到真机

未签名 HAP 无法直接安装。两种方式：

**A. DevEco Studio（推荐，自动签名）**
1. 用 DevEco 打开本工程。
2. `File > Project Structure > Signing Configs`，勾选 “Automatically generate signature”（需登录华为账号并连接真机）。
3. 连接已开启开发者模式与 USB 调试的鸿蒙设备，点 Run。

**B. 命令行 hdc 安装**（已有签名 HAP 时）
```bash
hdc install path/to/entry-default-signed.hap
```

设备需在“设置 > 系统 > 开发者选项”开启 USB 调试。

## 三、被控端（Windows）准备

1. 需 **专业版 / 企业版 / 教育版**（家庭版无远程桌面服务端）。
2. 设置 > 系统 > 远程桌面 > 打开“远程桌面”。
3. 记下电脑名或 IP（`ipconfig` 查看 IPv4 地址）。
4. 用于登录的账户需有密码；建议在“远程桌面 > 用户账户”中确认允许连接的用户。
5. 同一局域网直连；跨网络需自行处理端口转发/VPN（应用不含中转服务）。

## 四、使用

1. 打开 HMRDP，点右上角 `+` 添加电脑：填 IP（可带 `:端口`）、账户、显示设置。
   - 密码留空 = 每次连接时询问；填写则加密保存在系统关键资产存储。
2. 点电脑卡片连接。首次连接自签证书会弹“验证服务器证书”，确认指纹后信任。
3. 会话内：
   - 右下角工具条：软键盘、直接触摸/触控板切换、缩放复位、断开。
   - 双指捏合缩放、双指拖动平移。
   - 直接触摸模式：点触即点击，长按拖动，双指滑动滚动，双指轻点右键。
   - 触控板模式：单指移动指针，轻点左键，双指滑动滚动，双指轻点右键。

## 五、故障排查

| 现象 | 处理 |
| --- | --- |
| “无法连接到远程电脑” | 确认远程桌面已开启、IP/端口正确、双方在同一网络、防火墙放行 3389 |
| “登录失败：用户名或密码错误” | 核对账户；域账户用 `user@domain` 或 `domain\user` |
| 画面卡顿 | 优先保证 Windows 为 2012/8 以上以协商 H.264；降低分辨率；使用 5GHz Wi-Fi |
| 中文输入无效 | 用软键盘输入（走 Unicode）；部分输入法组合需在候选确认后上屏 |

真机日志：`hdc hilog | grep HMRDP` 可看连接与协议诊断（含 FreeRDP 内核日志）。
