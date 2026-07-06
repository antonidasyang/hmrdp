#!/bin/bash
# HMRDP 三方库交叉编译公共环境
# 用法: source env.sh  （可通过环境变量 OHOS_NATIVE_SDK 覆盖 SDK 路径）
set -euo pipefail

: "${OHOS_NATIVE_SDK:=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"

if [ ! -d "$OHOS_NATIVE_SDK/sysroot" ]; then
  echo "错误: 未找到 OHOS native SDK: $OHOS_NATIVE_SDK" >&2
  echo "请安装 DevEco Studio 或设置 OHOS_NATIVE_SDK 环境变量" >&2
  exit 1
fi

export OHOS_NATIVE_SDK
export OHOS_ARCH=arm64-v8a
export OHOS_TARGET=aarch64-linux-ohos
export OHOS_SYSROOT="$OHOS_NATIVE_SDK/sysroot"
export OHOS_LLVM="$OHOS_NATIVE_SDK/llvm"
export OHOS_TOOLCHAIN_CMAKE="$OHOS_NATIVE_SDK/build/cmake/ohos.toolchain.cmake"

export CC="$OHOS_LLVM/bin/clang"
export CXX="$OHOS_LLVM/bin/clang++"
export AR="$OHOS_LLVM/bin/llvm-ar"
export RANLIB="$OHOS_LLVM/bin/llvm-ranlib"
export STRIP="$OHOS_LLVM/bin/llvm-strip"

export OHOS_CFLAGS="--target=$OHOS_TARGET --sysroot=$OHOS_SYSROOT -fPIC -D__MUSL__ -DOHOS"

# 兼容 bash / zsh 两种 source 方式
TP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export TP_SRC="$TP_DIR/src"
export TP_BUILD="$TP_DIR/build"
export TP_PREBUILT="$TP_DIR/prebuilt/$OHOS_ARCH"
mkdir -p "$TP_SRC" "$TP_BUILD" "$TP_PREBUILT"

export JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# 版本锁定
export OPENSSL_VERSION=3.5.7
export FREERDP_VERSION=3.27.1
