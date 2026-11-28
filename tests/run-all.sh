#!/bin/sh
# CI 与 Release 共用的宿主测试；不碰真实 Android 或服务。
# 需要 python3（回环夹具）、JDK、shellcheck、Node.js 18+（内置 test，无 npm 包）。
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# Python 子套件也使用本轮自己的临时目录，退出时只回收该目录。
W=$(mktemp -d)
W=$(cd "$W" && pwd)
trap 'rm -rf "$W"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
TMPDIR=$W; export TMPDIR
cd "$ROOT"

echo "== 1 语法检查"
for f in service.sh action.sh uninstall.sh customize.sh build.sh tile-app/build.sh \
  scripts/magpie.service scripts/*.sh scripts/ci/*.sh tests/*.sh system/bin/magpie META-INF/com/google/android/update-binary; do
  sh -n "$f"
done
echo "语法检查通过"

echo
echo "== 2 shellcheck（只查生产脚本）"
# SC1090/SC1091：动态 source（先判断 lib.sh 在不在），刻意如此。
shellcheck -s sh -e SC1090,SC1091 \
  service.sh action.sh uninstall.sh customize.sh build.sh tile-app/build.sh \
  scripts/magpie.service scripts/*.sh scripts/ci/*.sh system/bin/magpie
# 两个变量由 source 进来的管理器 util_functions.sh 使用。
shellcheck -s sh -e SC1091,SC2034 META-INF/com/google/android/update-binary
echo "shellcheck 通过"

echo
echo "== 3 Shell 与 JVM：运行、计数并核对文档"
sh tests/check-counts.sh --verbose

echo
echo "== 4 宿主 Python 回归（独立于 Shell/JVM 断言总数）"
python3 tests/test-tile-lifecycle.py
python3 tests/test-launcher.py
python3 tests/test-doctor-tile.py
python3 tests/test-release-zip.py
python3 tests/test-tile-version.py
python3 tests/test-release-policy.py
python3 tests/test-installer-tls.py
python3 tests/test-counts.py
python3 tests/test-boot-policy.py
python3 tests/test-tile-install.py
python3 tests/test-runtime-boundaries.py

echo
echo "== 5 WebUI 状态与导航（Node.js 18+，无需 npm 依赖）"
node --test tests/test-webui.js

echo
echo "全部公共测试通过"
