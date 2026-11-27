#!/bin/sh
# 本地构建完整的已签名模块包。正式 CI 将构建、签名和发布分开，不调用这个组合入口。
set -eu
cd "$(dirname "$0")"
OUT=${1:-dist}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "$OUT/.module-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
sh tile-app/build.sh "$WORK"
python3 -I scripts/ci/release-artifacts.py package --source "$PWD" \
  --apk "$WORK/magpie-tile.apk" --output "$OUT"
