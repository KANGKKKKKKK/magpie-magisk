#!/bin/sh
# 本地构建完整的已签名模块包。正式 CI 将构建、签名和发布分开，不调用这个组合入口。
set -eu
[ "$#" -le 1 ] || { echo "用法: sh build.sh [输出目录]" >&2; exit 2; }
cd "$(dirname "$0")"
OUT=${1:-dist}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "$OUT/.module-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# 有签名密钥就现编现签；没有时用仓库根目录里已签好的 magpie-tile.apk
# （.gitignore 忽略它，正是为了留给这种本地构建）。两者都没有就明确失败。
if [ -n "${MAGPIE_KEYSTORE:-}" ]; then
  sh tile-app/build.sh "$WORK"
  APK="$WORK/magpie-tile.apk"
elif [ -f magpie-tile.apk ]; then
  echo "未设置 MAGPIE_KEYSTORE，先核验已有磁贴的元数据与可信签名" >&2
  APK="$PWD/magpie-tile.apk"
else
  echo "没有签名密钥（MAGPIE_KEYSTORE），也没有现成的 magpie-tile.apk，无法打包" >&2
  exit 1
fi
# 始终先在同一文件系统的私有目录打包，校验失败不覆盖已有输出。
ZIP=$(python3 -I scripts/ci/release-artifacts.py package --source "$PWD" --apk "$APK" --output "$WORK")
if [ -z "${MAGPIE_KEYSTORE:-}" ]; then
  VERSION=$(sed -n 's/^version=//p' module.prop)
  SOURCE_ROOT="$PWD" sh scripts/ci/verify-release-zip.sh "$ZIP" "$VERSION"
fi
mv -fT "$ZIP" "$OUT/${ZIP##*/}"
printf '%s\n' "$OUT/${ZIP##*/}"
