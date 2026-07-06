#!/bin/bash
# 一键交叉编译全部三方依赖（OpenSSL -> FreeRDP）到 OHOS arm64-v8a
set -euo pipefail
cd "$(dirname "$0")"

./build_openssl.sh
./build_freerdp.sh

echo ""
echo "全部三方库就绪："
ls -1 prebuilt/arm64-v8a/lib/*.a
