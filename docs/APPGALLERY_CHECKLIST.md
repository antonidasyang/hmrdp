# 华为应用市场（AppGallery Connect）上架清单

## 一、账号与资质
- [ ] 注册华为开发者账号并完成实名认证（个人或企业）。
- [ ] 在 AGC 创建应用，**包名填 `com.d2ssoft.hmrdp`**（须与 `AppScope/app.json5` 一致，创建后不可改）。
- [ ] 应用分类建议：工具 / 效率。

## 二、软件著作权（免费开源发布同样需要）
- [ ] 远程控制类应用，华为通常要求提供**计算机软件著作权登记证书**。
      本项目开源（Apache-2.0），著作权仍归开发者 d2ssoft，可正常申请软著。
- [ ] 若上架审核要求“远程控制类”特殊资质说明，附软著 + 功能说明（本应用为标准 RDP 客户端，
      不含隐蔽安装/后台静默控制，需用户在设备上主动发起连接）。

## 三、必备材料
- [ ] 应用图标（已内置分层图标，`AppScope/resources/base/media/`，另备 216×216 市场用图）。
- [ ] 应用名称：HMRDP（远程桌面）。
- [ ] 一句话简介与详细介绍（强调：开源免费、点对点直连、不收集数据）。
- [ ] 截图（真机会话页、电脑列表页、添加电脑页）。
- [ ] **隐私政策 URL**：将 `docs/PRIVACY_POLICY.md` 内容发布到可公开访问的网址后填入。
- [ ] 权限使用说明：
      - `ohos.permission.INTERNET`：与用户指定的远程电脑建立 RDP 连接。
      - `ohos.permission.GET_NETWORK_INFO`：检测网络状态用于连接与重连提示。

## 四、合规要点
- [ ] 隐私政策与实际行为一致：本应用零收集、无第三方 SDK、数据仅点对点传输（已满足）。
- [ ] 开源合规：应用内“关于 > 开源许可”页已展示 FreeRDP/OpenSSL/zlib 声明；
      随包保留 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md`。
- [ ] 内容分级：无不良信息；提示用户仅连接授权设备（已在关于页与介绍中说明）。
- [ ] 免责声明：家庭版 Windows 无 RDP 服务端（已在介绍/文档中说明）。

## 五、构建发布包
- [ ] 用 release 模式构建并**用正式发布证书签名**（AGC 申请发布证书 `.cer` 与 profile `.p7b`，
      在 DevEco `Signing Configs` 配置后打 release 签名 HAP/APP）。
- [ ] 上传 `.app`（AppGallery 需 app 包，非 hap）；DevEco `Build > Build App(s)` 生成。
- [ ] 填写版本号 1.0.0 / versionCode 1000000（与 `AppScope/app.json5` 一致）。

## 六、提交审核
- [ ] 提交后关注审核反馈；远程控制类可能需补充材料，按提示回复即可。

> 说明：签名证书与私钥（.p12/.cer/.p7b）**不要提交到仓库**，`.gitignore` 已排除。
