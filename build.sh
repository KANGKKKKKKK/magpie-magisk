#!/bin/sh
# 打包成可刷入的 zip：sh build.sh [输出目录]
# 产物: magpie-v<版本>.zip（需要 zip 命令）

cd "$(dirname "$0")" || exit 1
OUT=${1:-.}
VER=$(sed -n 's/^version=//p' module.prop)
ZIP="$OUT/magpie-${VER}.zip"

rm -f "$ZIP"
# 排除运行时产物与仓库文件，只打模块实际需要的东西
zip -r -9 "$ZIP" \
  module.prop customize.sh service.sh action.sh uninstall.sh \
  scripts webroot/index.html \
  META-INF \
  -x 'webroot/status.json' -x 'webroot/lastlog.txt' >/dev/null

if [ -f "$ZIP" ]; then
  echo "已生成 $ZIP ($(stat -c %s "$ZIP") 字节)"
else
  echo "打包失败" >&2
  exit 1
fi
