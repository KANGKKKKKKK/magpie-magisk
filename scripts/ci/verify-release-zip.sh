#!/bin/sh
# 发版 zip 的硬门槛校验。Release workflow 在打包之后、上传之前跑这一份。
#
#   sh scripts/ci/verify-release-zip.sh <zip> <tag>
#
# 缺任何一项都直接 exit 1（正式 Release 不允许「警告后继续」）：
#   * zip 必须能 unzip -t，无 zip slip（../ 或绝对路径）、无重复条目
#   * module.prop 在根目录，versionCode 纯数字
#   * 必需文件齐全（service.sh / action.sh / uninstall.sh / scripts/magpie.service / META-INF/...）
#   * 磁贴 App：magpie-tile.apk 与 tile-version 成对；apksigner --print-certs 指纹
#     必须等于 scripts/ci/tile-cert-sha256.txt 里那条公开预期值
#   * APK 包名 / versionCode / min / target 必须与源码 manifest 一致
#
# versionCode 递增、tag 属于 main、CI 成功、上传后 digest 对账由 release.yml 里
# 另外几步负责（需要 GitHub 上下文，不适合塞进这个独立脚本）。
set -eu

ZIP=${1:-}
TAG=${2:-}
# 守卫：参数缺失或 zip 不存在直接退出（a && b || c 是有意的短路守卫，不是 if-then-else）
# shellcheck disable=SC2015
[ -n "$ZIP" ] && [ -f "$ZIP" ] || { echo "::error::用法: $0 <zip> <tag>（zip 不存在：$ZIP）"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"

fail() { echo "::error::$*"; exit 1; }

# 期望的 APK 元数据直接读源码 manifest：APK 必须与源码一致，不允许打包机漂移。
EXPECTED_PKG=$(sed -n 's/.*package="\([^"]*\)".*/\1/p' tile-app/AndroidManifest.xml | head -1)
EXPECTED_VCODE=$(sed -n 's/.*android:versionCode="\([0-9][0-9]*\)".*/\1/p' tile-app/AndroidManifest.xml | head -1)
EXPECTED_MIN=$(sed -n 's/.*android:minSdkVersion="\([0-9][0-9]*\)".*/\1/p' tile-app/AndroidManifest.xml | head -1)
EXPECTED_TARGET=$(sed -n 's/.*android:targetSdkVersion="\([0-9][0-9]*\)".*/\1/p' tile-app/AndroidManifest.xml | head -1)
EXPECTED_CERT=$(grep -vE '^\s*#|^\s*$' scripts/ci/tile-cert-sha256.txt | head -1 | tr -d ' :\r' | tr 'a-f' 'A-F')

echo "== zip 完整性"
unzip -t "$ZIP" >/dev/null || fail "unzip -t 失败：zip 损坏"

LIST=$(unzip -Z1 "$ZIP")

# zip slip：任何 ../ 、以 / 开头、含反斜杠的条目都拒绝
if printf '%s\n' "$LIST" | grep -qE '(^|/)\.\.(/|$)|^/|\\'; then
  echo "$LIST" | grep -E '(^|/)\.\.(/|$)|^/|\\' | sed 's/^/  危险条目: /'
  fail "zip 里有 zip slip / 绝对路径条目"
fi

# 重复条目：同名出现两次说明打包逻辑出问题（zip -r 重复 add 会留两份）
_dup=$(printf '%s\n' "$LIST" | sed '/\/$/d' | sort | uniq -d)
[ -z "$_dup" ] || { printf '%s\n' "$_dup" | sed 's/^/  重复条目: /'; fail "zip 里有重复条目"; }

echo "== 必需文件"
printf '%s\n' "$LIST" | grep -qx 'module.prop' || fail "module.prop 不在 zip 根目录"
for f in service.sh action.sh uninstall.sh customize.sh scripts/magpie.service; do
  printf '%s\n' "$LIST" | grep -qx "$f" || fail "zip 缺少 $f"
done
# Magisk 刷入脚本：没有它整个 zip 装不上
for f in META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script; do
  printf '%s\n' "$LIST" | grep -qx "$f" || fail "zip 缺少 $f（Magisk 无法刷入）"
done
# 仓库文件不该混进去
if printf '%s\n' "$LIST" | grep -qxE '(README\.md|LICENSE|CHANGELOG\.md|update\.json|build\.sh)'; then
  fail "zip 里混进了仓库文件"
fi

echo "== module.prop versionCode"
VCODE=$(unzip -p "$ZIP" module.prop | sed -n 's/^versionCode=//p' | tr -d '\r' | head -1)
case "$VCODE" in ''|*[!0-9]*) fail "versionCode 不是纯数字：[$VCODE]" ;; esac
echo "  zip versionCode=$VCODE"

echo "== 磁贴 App"
HAS_APK=$(printf '%s\n' "$LIST" | grep -cx 'magpie-tile.apk')
HAS_VER=$(printf '%s\n' "$LIST" | grep -cx 'tile-version')
if [ "$HAS_APK" = 0 ] || [ "$HAS_VER" = 0 ]; then
  fail "正式 Release 必须同时包含 magpie-tile.apk 与 tile-version（apk=$HAS_APK ver=$HAS_VER）；缺签名 secret 时应在打包步骤直接失败，而不是降级出不含磁贴的包"
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
unzip -o -q "$ZIP" magpie-tile.apk tile-version -d "$W"

TILE_VER_IN_ZIP=$(tr -d '\r' < "$W/tile-version")
case "$TILE_VER_IN_ZIP" in ''|*[!0-9]*) fail "tile-version 不是纯数字：[$TILE_VER_IN_ZIP]" ;; esac

echo "== apksigner 证书指纹"
# apksigner 来自 Android build-tools（apt 的 apksigner 包或 $ANDROID_HOME）。
APKSIGNER=$(command -v apksigner || true)
if [ -z "$APKSIGNER" ]; then
  for _cand in "${ANDROID_HOME:-/nonexistent}"/build-tools/*/apksigner; do
    [ -x "$_cand" ] && APKSIGNER=$_cand && break
  done
fi
[ -n "$APKSIGNER" ] || fail "找不到 apksigner，无法校验磁贴签名（CI 需安装）"
# apksigner --print-certs 的真实输出形如：
#   V3.0 Signer: certificate SHA-256 digest: 217cac85...ff6   （小写、无冒号）
# 取第一个 SHA-256 digest，去掉冒号/空格并统一大写后逐字比对。
ACTUAL_CERT=$("$APKSIGNER" verify --print-certs "$W/magpie-tile.apk" 2>/dev/null \
  | sed -n 's/.*certificate SHA-256 digest: //p' | head -1 | tr -d ' :\r' | tr 'a-f' 'A-F')
[ -n "$ACTUAL_CERT" ] || fail "apksigner 没吐出证书指纹（APK 可能没签名）"
echo "  实际指纹: $ACTUAL_CERT"
echo "  预期指纹: $EXPECTED_CERT"
[ "$ACTUAL_CERT" = "$EXPECTED_CERT" ] || fail "磁贴证书指纹不匹配（签名 key 不对，或仓库预期值过期）"

echo "== APK 包名 / versionCode / min / target"
# aapt dump badging 输出里逐字段抠，避免任何「看起来对就行」的判断
BADGE=$(aapt dump badging "$W/magpie-tile.apk" 2>/dev/null)
APK_PKG=$(printf '%s\n' "$BADGE" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)
APK_VCODE=$(printf '%s\n' "$BADGE" | sed -n "s/^package: .*versionCode='\([^']*\)'.*/\1/p" | head -1)
APK_MIN=$(printf '%s\n' "$BADGE" | sed -n "s/^sdkVersion:'\([^']*\)'.*/\1/p" | head -1)
APK_TARGET=$(printf '%s\n' "$BADGE" | sed -n "s/^targetSdkVersion:'\([^']*\)'.*/\1/p" | head -1)

[ "$APK_PKG" = "$EXPECTED_PKG" ]       || fail "APK 包名 $APK_PKG != 源码 $EXPECTED_PKG"
[ "$APK_VCODE" = "$EXPECTED_VCODE" ]   || fail "APK versionCode $APK_VCODE != 源码 $EXPECTED_VCODE"
[ "$APK_MIN" = "$EXPECTED_MIN" ]       || fail "APK minSdk $APK_MIN != 源码 $EXPECTED_MIN"
[ "$APK_TARGET" = "$EXPECTED_TARGET" ] || fail "APK targetSdk $APK_TARGET != 源码 $EXPECTED_TARGET"
# tile-version（安装器据此判断要不要重装）必须等于 APK 真实 versionCode
[ "$TILE_VER_IN_ZIP" = "$APK_VCODE" ]  || fail "tile-version $TILE_VER_IN_ZIP != APK versionCode $APK_VCODE"

echo "  APK $APK_PKG v$APK_VCODE min=$APK_MIN target=$APK_TARGET —— 与源码一致"
echo
echo "zip 硬门槛校验全部通过: $ZIP${TAG:+ (tag $TAG)}"
