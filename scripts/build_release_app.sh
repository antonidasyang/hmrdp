#!/bin/bash
# 构建【已签名】release .app（用于上传华为应用市场）。
# 签名材料从 signing.local.json5 读取（gitignored，不入库）；
# 构建时临时把 signingConfigs 注入 build-profile.json5，构建后立即还原，
# 保证密码永不进入 git 跟踪的文件。
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNING="signing.local.json5"
BP="build-profile.json5"

if [ ! -f "$SIGNING" ]; then
  echo "错误：缺少 $SIGNING。请复制 signing.local.json5.example 并填入签名材料。" >&2
  exit 1
fi

# 校验 profile 存在（HMRDP 专用，需在 AGC 为 com.d2ssoft.hmrdp 申请）
PROFILE=$(python3 -c "import json;print(json.load(open('$SIGNING'))['material']['profile'])")
if [ ! -f "$PROFILE" ]; then
  echo "错误：找不到发布 Profile：$PROFILE" >&2
  echo "请先在 AppGallery Connect 为 bundleName com.d2ssoft.hmrdp 申请发布 Profile，" >&2
  echo "下载 .p7b 后放到该路径（或改 signing.local.json5 的 profile 字段）。" >&2
  exit 1
fi

DEVECO=/Applications/DevEco-Studio.app/Contents
export NODE_HOME="$DEVECO/tools/node"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export PATH="$NODE_HOME/bin:$JAVA_HOME/bin:$PATH"
export DEVECO_SDK_HOME="$DEVECO/sdk"

# 备份并在退出时还原 build-profile.json5（确保签名密码不残留在入库文件）
cp "$BP" "$BP.bak"
restore() { mv -f "$BP.bak" "$BP"; }
trap restore EXIT

# 注入 signingConfigs
python3 - "$BP" "$SIGNING" <<'PY'
import json, sys, re
bp_path, signing_path = sys.argv[1], sys.argv[2]
signing = json.load(open(signing_path))
text = open(bp_path).read()
block = json.dumps([signing], ensure_ascii=False, indent=6)
# 将空的 signingConfigs 数组替换为完整签名块
new = re.sub(r'"signingConfigs"\s*:\s*\[\s*\]', '"signingConfigs": ' + block, text, count=1)
if new == text:
    sys.stderr.write("未找到可注入的 signingConfigs:[]，请检查 build-profile.json5\n")
    sys.exit(1)
open(bp_path, 'w').write(new)
PY

echo "==> 构建已签名 release .app"
"$DEVECO/tools/hvigor/bin/hvigorw" assembleApp \
  --mode project -p product=default -p buildMode=release --no-daemon

echo ""
echo "签名产物："
find build/outputs -name "*.app" ! -name "*unsigned*" 2>/dev/null || find build/outputs -name "*.app"
