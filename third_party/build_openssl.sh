#!/bin/bash
# 交叉编译 OpenSSL（静态库）到 OHOS arm64-v8a
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

TARBALL="$TP_SRC/openssl-$OPENSSL_VERSION.tar.gz"
SRCDIR="$TP_BUILD/openssl-$OPENSSL_VERSION"
STAMP="$TP_PREBUILT/.openssl-$OPENSSL_VERSION.done"

if [ -f "$STAMP" ]; then
  echo "OpenSSL $OPENSSL_VERSION 已构建，跳过（删除 $STAMP 可强制重建）"
  exit 0
fi

if [ ! -f "$TARBALL" ]; then
  echo "==> 下载 OpenSSL $OPENSSL_VERSION"
  curl -fL --retry 3 -o "$TARBALL" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
fi

rm -rf "$SRCDIR"
tar -xzf "$TARBALL" -C "$TP_BUILD"

cd "$SRCDIR"
echo "==> Configure (linux-aarch64, static, no-engine/no-module)"
./Configure linux-aarch64 \
  no-shared no-tests no-engine no-module no-dso \
  --prefix="$TP_PREBUILT" --libdir=lib \
  CC="$CC" CFLAGS="$OHOS_CFLAGS -O2" AR="$AR" RANLIB="$RANLIB"

echo "==> make build_libs -j$JOBS"
make build_libs -j"$JOBS" >/dev/null

echo "==> 安装头文件与静态库"
make install_dev >/dev/null

touch "$STAMP"
echo "==> OpenSSL 完成: $(ls "$TP_PREBUILT"/lib/libssl.a "$TP_PREBUILT"/lib/libcrypto.a)"
