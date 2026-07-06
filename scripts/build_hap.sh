#!/bin/bash
# 命令行构建 HAP（使用 DevEco Studio 自带工具链，无需额外安装 node/java）
# 用法: scripts/build_hap.sh [debug|release]  （默认 debug，未签名）
set -euo pipefail
cd "$(dirname "$0")/.."

DEVECO=/Applications/DevEco-Studio.app/Contents
export NODE_HOME="$DEVECO/tools/node"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export PATH="$NODE_HOME/bin:$JAVA_HOME/bin:$PATH"
export DEVECO_SDK_HOME="$DEVECO/sdk"

MODE="${1:-debug}"

"$DEVECO/tools/hvigor/bin/hvigorw" assembleHap \
  --mode module -p product=default -p buildMode="$MODE" --no-daemon

echo ""
echo "产物:"
find entry/build -name "*.hap" -newer build-profile.json5 2>/dev/null || find entry/build -name "*.hap"
