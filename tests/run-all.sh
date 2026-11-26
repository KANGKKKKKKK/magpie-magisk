#!/bin/sh
# 全套 CI/Release 公共测试：语法检查 + shellcheck + 断言计数 + JVM 单测 + shell 套件。
#
#   sh tests/run-all.sh            # 桌面/CI 跑全套
#
# CI（ci.yml）与 Release（release.yml）共用这一份，避免两份流程漂移：
# 一边加了新测试、另一边忘了加，发出去的包就没被那一道拦住。
#
# 需要 python3（夹具静态服务）、javac/java（JVM 单测）、shellcheck。
# 全程在临时目录里跑，不碰真实服务与真实 Android。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT"

echo "== 1 语法检查"
for f in service.sh action.sh uninstall.sh customize.sh scripts/magpie.service scripts/*.sh tests/*.sh; do
  sh -n "$f"
done
echo "语法检查通过"

echo
echo "== 2 shellcheck（只查生产脚本）"
# 只查生产脚本：测试文件里大量 `a && b || c` 是刻意写法，查出来全是风格噪音。
# SC1090/SC1091：动态 source（先判断 lib.sh 在不在），刻意如此。
shellcheck -s sh -e SC1090,SC1091 \
  service.sh action.sh uninstall.sh customize.sh scripts/magpie.service scripts/*.sh
echo "shellcheck 通过"

echo
echo "== 3 文档断言计数与实际一致"
sh tests/check-counts.sh

echo
echo "== 4 磁贴状态判定 / 自查 / Shell 执行（纯 JVM，不依赖 Android SDK）"
W=$(mktemp -d)
javac -encoding UTF-8 tests/jvm/ClassifyTest.java -d "$W"
java -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$W" ClassifyTest

W2=$(mktemp -d)
javac -encoding UTF-8 tile-app/src/com/ruin/magpie/tile/SelfCheck.java \
  tests/jvm/SelfCheckTest.java -d "$W2"
java -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$W2" \
  com.ruin.magpie.tile.SelfCheckTest

W3=$(mktemp -d)
mkdir -p "$W3/stubs/android/os" "$W3/classes"
cat > "$W3/stubs/android/os/Looper.java" <<'JAVA'
package android.os; public class Looper { public static Looper getMainLooper() { return new Looper(); } }
JAVA
cat > "$W3/stubs/android/os/Handler.java" <<'JAVA'
package android.os; public class Handler { public Handler(Looper l) {} public boolean post(Runnable r) { r.run(); return true; } }
JAVA
javac -encoding UTF-8 -d "$W3/classes" "$W3"/stubs/android/os/*.java \
  tile-app/src/com/ruin/magpie/tile/Shell.java tests/jvm/ShellTest.java
java -cp "$W3/classes" com.ruin.magpie.tile.ShellTest

echo
echo "== 5 shell 行为套件（夹具 + 静态服务）"
python3 tests/make-fixtures.py /tmp/fx
( cd /tmp/fx && exec python3 -m http.server 8899 --bind 127.0.0.1 ) &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null || true' EXIT
sleep 1

TEST_SRV=http://127.0.0.1:8899 sh tests/test-install.sh
sh tests/test-watchdog.sh
TEST_SRV=http://127.0.0.1:8899 sh tests/test-action.sh
sh tests/test-service.sh
sh tests/test-lib.sh

echo
echo "全部公共测试通过"
