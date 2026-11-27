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

# 所有本轮临时产物都归一个私有目录；只回收本脚本启动的夹具服务 PID。
W=$(mktemp -d)
SRV_PID=
cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$W"
}
trap cleanup EXIT
# 信号只负责退出，EXIT 统一清理，不能清理后又继续执行后续测试。
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== 1 语法检查"
for f in service.sh action.sh uninstall.sh customize.sh build.sh tile-app/build.sh \
  scripts/magpie.service scripts/*.sh scripts/ci/*.sh tests/*.sh; do
  sh -n "$f"
done
echo "语法检查通过"

echo
echo "== 2 shellcheck（只查生产脚本）"
# 只查生产脚本：测试文件里大量 `a && b || c` 是刻意写法，查出来全是风格噪音。
# SC1090/SC1091：动态 source（先判断 lib.sh 在不在），刻意如此。
shellcheck -s sh -e SC1090,SC1091 \
  service.sh action.sh uninstall.sh customize.sh build.sh tile-app/build.sh \
  scripts/magpie.service scripts/*.sh scripts/ci/*.sh
echo "shellcheck 通过"

echo
echo "== 3 文档断言计数与实际一致"
sh tests/check-counts.sh

echo
echo "== 4 磁贴状态判定 / 自查 / Shell / SerialExecutor（有界纯 JVM）"
sh tests/run-jvm.sh
python3 tests/test-tile-lifecycle.py
python3 tests/test-launcher.py
python3 tests/test-doctor-tile.py

echo
echo "== 5 shell 行为套件（夹具 + 静态服务）"
python3 tests/make-fixtures.py "$W/fixtures"
# 端口保留 8899 与历史夹具兼容，但绝不清理占用端口的别的进程。
# 只有本轮服务成功 bind 后才写 ready，避免误用其他进程提供的 HTTP 服务。
python3 - "$W/fixtures" "$W/server.ready" >"$W/server.log" 2>&1 <<'PY' &
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
handler = partial(SimpleHTTPRequestHandler, directory=sys.argv[1])
with ThreadingHTTPServer(("127.0.0.1", 8899), handler) as server:
    server.daemon_threads = True
    Path(sys.argv[2]).touch()
    server.serve_forever()
PY
SRV_PID=$!
_tries=0
while [ ! -f "$W/server.ready" ]; do
  if ! kill -0 "$SRV_PID" 2>/dev/null || [ "$_tries" -ge 50 ]; then
    cat "$W/server.log" >&2
    echo "夹具服务未就绪（端口 8899 可能已被占用），拒绝继续" >&2
    exit 1
  fi
  _tries=$((_tries + 1))
  sleep 0.1
done

TEST_SRV=http://127.0.0.1:8899 sh tests/test-install.sh
sh tests/test-watchdog.sh
TEST_SRV=http://127.0.0.1:8899 sh tests/test-action.sh
sh tests/test-service.sh
sh tests/test-lib.sh
sh tests/test-tile-check.sh

echo
echo "== 6 Release ZIP / tile build / versionCode 回归（独立于 Shell 断言总数）"
python3 tests/test-release-zip.py
python3 tests/test-tile-version.py
python3 tests/test-release-policy.py
python3 tests/test-installer-tls.py

echo
echo "全部公共测试通过"
