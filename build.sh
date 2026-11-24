#!/bin/sh
# 打包成可刷入的 zip：sh build.sh [输出目录]
# 产物: magpie-v<版本>.zip（需要 zip 命令）
#
# 磁贴 App 会在打包前重新构建（如果提供了签名密钥），然后塞进 zip 根目录。
# 没有密钥时用仓库里预置的那份 APK —— 发版机没有密钥也能打包，
# 但那种包里的 APK 可能是旧的，所以会打一行警告。

cd "$(dirname "$0")" || exit 1
OUT=${1:-.}
# 输出目录不存在就建出来：CI 里是 workflow 先 mkdir，本地给个新路径就会打不出来
[ -d "$OUT" ] || mkdir -p "$OUT" || { echo "建不了输出目录：$OUT" >&2; exit 1; }
VER=$(sed -n 's/^version=//p' module.prop)
ZIP="$OUT/magpie-${VER}.zip"

# ---- 磁贴 App ----
TILE_SRC="$PWD/tile-app"
TILE_APK="$PWD/magpie-tile.apk"
if [ -n "${MAGPIE_KEYSTORE:-}" ] && [ -f "${MAGPIE_KEYSTORE}" ] && [ -n "${MAGPIE_KS_PASS:-}" ]; then
  echo "构建磁贴 App ..."
  # 不吞输出：构建失败时最需要看到的就是它自己报的那句
  # （缺 aapt / 缺 android.jar / 签名失败……）。
  # 传绝对路径：tile-app/build.sh 内部会 cd，相对路径会落到它自己的目录里
  TILE_OUT="$PWD/.tile-build"
  if ! sh "$TILE_SRC/build.sh" "$TILE_OUT"; then
    echo "磁贴 App 构建失败" >&2
    exit 1
  fi
  cp -f "$TILE_OUT/magpie-tile.apk" "$TILE_APK"
  rm -rf "$TILE_OUT"
else
  if [ -f "$TILE_APK" ]; then
    echo "警告：没有签名密钥，使用仓库里现成的 magpie-tile.apk（可能不是最新）" >&2
  else
    echo "警告：没有签名密钥也没有现成 APK，本次打包不含磁贴 App" >&2
  fi
fi

# 写版本号给 tile-app.sh 判断要不要更新
# 版本号从源码 manifest 读：二进制 manifest 用 shell 解析太脆弱
TILE_CODE=$(sed -n 's/.*android:versionCode="\([0-9][0-9]*\)".*/\1/p' "$TILE_SRC/AndroidManifest.xml" | head -1)
[ -n "$TILE_CODE" ] || TILE_CODE=1
printf '%s\n' "$TILE_CODE" > "$PWD/tile-version"

rm -f "$ZIP"
# 排除运行时产物与仓库文件，只打模块实际需要的东西
zip -r -9 "$ZIP" \
  module.prop customize.sh service.sh action.sh uninstall.sh \
  scripts webroot/index.html system \
  META-INF \
  -x 'webroot/status.json' -x 'webroot/lastlog.txt' >/dev/null

# APK 与版本号单独加进去（放在 zip 根目录，customize.sh 直接从 $MODPATH 取）
if [ -f "$TILE_APK" ]; then
  zip -9 "$ZIP" magpie-tile.apk tile-version >/dev/null
fi

rm -f "$PWD/tile-version"

if [ -f "$ZIP" ]; then
  echo "已生成 $ZIP ($(stat -c %s "$ZIP") 字节)"
  if [ -f "$TILE_APK" ]; then
    echo "  含磁贴 App：versionCode $TILE_CODE"
  fi
else
  echo "打包失败" >&2
  exit 1
fi
