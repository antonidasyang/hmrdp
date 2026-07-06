#!/bin/bash
# 交叉编译 FreeRDP 3.x（libfreerdp/libwinpr/client-common，静态库）到 OHOS arm64-v8a
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

TARBALL="$TP_SRC/freerdp-$FREERDP_VERSION.tar.gz"
SRCDIR="$TP_BUILD/FreeRDP-$FREERDP_VERSION"
BUILDDIR="$TP_BUILD/freerdp-build"
STAMP="$TP_PREBUILT/.freerdp-$FREERDP_VERSION.done"
PATCH_DIR="$(pwd)/patches/freerdp"

if [ -f "$STAMP" ]; then
  echo "FreeRDP $FREERDP_VERSION 已构建，跳过（删除 $STAMP 可强制重建）"
  exit 0
fi

if [ ! -f "$TARBALL" ]; then
  echo "==> 下载 FreeRDP $FREERDP_VERSION"
  curl -fL --retry 3 -o "$TARBALL" \
    "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$FREERDP_VERSION.tar.gz"
fi

rm -rf "$SRCDIR" "$BUILDDIR"
tar -xzf "$TARBALL" -C "$TP_BUILD"

# 拷入 OHOS H.264 硬解子系统源码（补丁负责注册与构建接线）
cp "$(pwd)/freerdp_ohos/h264_ohos.c" "$SRCDIR/libfreerdp/codec/h264_ohos.c"

# 应用 OHOS 适配补丁（按文件名顺序）
if compgen -G "$PATCH_DIR/*.patch" >/dev/null; then
  for p in "$PATCH_DIR"/*.patch; do
    echo "==> 应用补丁 $(basename "$p")"
    patch -d "$SRCDIR" -p1 <"$p"
  done
fi

echo "==> CMake configure"
cmake -S "$SRCDIR" -B "$BUILDDIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN_CMAKE" \
  -DOHOS_ARCH="$OHOS_ARCH" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$TP_PREBUILT" \
  -DCMAKE_FIND_ROOT_PATH="$TP_PREBUILT" \
  -DCMAKE_C_FLAGS="-D__MUSL__ -DOHOS -DWITH_OHOS_CODEC" \
  -DWITH_OHOS_CODEC=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DOPENSSL_ROOT_DIR="$TP_PREBUILT" \
  -DOPENSSL_USE_STATIC_LIBS=ON \
  -DWITH_SERVER=OFF \
  -DWITH_SHADOW=OFF \
  -DWITH_PROXY=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_X11=OFF \
  -DWITH_WAYLAND=OFF \
  -DWITH_MANPAGES=OFF \
  -DWITH_KRB5=OFF \
  -DWITH_CUPS=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_PKCS11=OFF \
  -DWITH_FUSE=OFF \
  -DWITH_ALSA=OFF -DWITH_PULSE=OFF -DWITH_OSS=OFF -DWITH_OPENSLES=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_MEDIACODEC=OFF \
  -DWITH_VIDEO_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF \
  -DWITH_OPUS=OFF -DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_SOXR=OFF \
  -DWITH_CAIRO=OFF \
  -DWITH_URIPARSER=OFF \
  -DWITH_LIBSYSTEMD=OFF \
  -DWITH_WEBVIEW=OFF \
  -DWITH_INTERNAL_RC4=ON \
  -DWITH_INTERNAL_MD4=ON \
  -DWITH_INTERNAL_MD5=ON \
  -DWITH_UNICODE_BUILTIN=ON \
  -DCHANNEL_URBDRC=OFF \
  -DCHANNEL_REMDESK=OFF \
  -DWITH_ICU=OFF

echo "==> ninja -j$JOBS"
cmake --build "$BUILDDIR" -j "$JOBS"

echo "==> 安装"
cmake --install "$BUILDDIR" >/dev/null

touch "$STAMP"
echo "==> FreeRDP 完成:"
ls "$TP_PREBUILT"/lib/libfreerdp3.a "$TP_PREBUILT"/lib/libwinpr3.a "$TP_PREBUILT"/lib/libfreerdp-client3.a 2>/dev/null || ls "$TP_PREBUILT"/lib/ | grep -E 'freerdp|winpr'
