# 第三方开源软件声明 / Third-Party Notices

HMRDP 使用了以下第三方开源组件。我们感谢这些项目及其贡献者。
HMRDP bundles or links against the following third-party open source
components. We are grateful to these projects and their contributors.

---

## FreeRDP

- 项目地址: https://github.com/FreeRDP/FreeRDP
- 用途: RDP 协议核心实现（libfreerdp / libwinpr）
- 许可证: Apache License 2.0
- 版权: Copyright FreeRDP contributors

> Licensed under the Apache License, Version 2.0 (the "License"); you may
> not use this file except in compliance with the License. You may obtain
> a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

本仓库对 FreeRDP 的修改（OpenHarmony 平台适配补丁）位于
`third_party/patches/freerdp/`，同样以 Apache License 2.0 发布。

## OpenSSL

- 项目地址: https://www.openssl.org/
- 用途: TLS 传输加密与 NLA/CredSSP 认证所需的密码学原语
- 许可证: Apache License 2.0（OpenSSL 3.x）
- 版权: Copyright The OpenSSL Project Authors

## zlib

- 项目地址: https://zlib.net/
- 用途: RDP 数据压缩
- 许可证: zlib License
- 版权: Copyright (C) 1995-2024 Jean-loup Gailly and Mark Adler

> This software is provided 'as-is', without any express or implied
> warranty. In no event will the authors be held liable for any damages
> arising from the use of this software.

---

各组件的完整许可证文本随源码分发，亦可在上述项目主页获取。
应用内「关于 → 开源许可」页面同步展示本声明。
