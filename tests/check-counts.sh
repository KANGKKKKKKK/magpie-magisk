#!/bin/sh
# 公共入口：实跑 Shell / JVM 各一次，核对同一轮的输出与文档；失败时打印原始日志。
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/check-counts.py" "$@"
