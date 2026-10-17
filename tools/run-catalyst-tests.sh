#!/bin/bash
# 由 tools/devserver 的 HTTP 服务执行（服务是 launchd 拉起的，不在 WorkBuddy 沙盒里）。
# 用途：在本机 Mac Catalyst 上跑全量单元测试。

set -o pipefail
cd "$(dirname "$0")/.." || exit 1

echo "===== START $(date '+%Y-%m-%d %H:%M:%S') ====="
echo "pwd=$(pwd)"
echo "xcodebuild: $(xcodebuild -version 2>&1 | tr '\n' ' ')"
echo "user=$(id -un)"

# 同一份 DerivedData 上如果在跑 App，会干扰测试注入，先停掉
if pkill -f 'MarkdownEditorHy4.app/Contents/MacOS/MarkdownEditorHy4' 2>/dev/null; then
  echo "已停掉之前运行的 App"
fi

# 结果包路径固定，方便事后用 xcresulttool 读；旧的先挪走（只在 build/ 下动）
BUNDLE="build/unit-catalyst.xcresult"
rm -rf build/unit-catalyst-prev.xcresult
if [ -d "$BUNDLE" ]; then
  mv "$BUNDLE" build/unit-catalyst-prev.xcresult
fi

xcodebuild test \
  -scheme MarkdownEditorHy4 \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:MarkdownEditorHy4Tests \
  -enableCodeCoverage YES \
  -resultBundlePath "$BUNDLE"

CODE=$?
echo "===== EXIT $CODE at $(date '+%Y-%m-%d %H:%M:%S') ====="
exit $CODE
