#!/system/bin/sh
# 磁贴 App 的安装/卸载辅助，被 customize.sh 与 service.sh 共用。
#
# 为什么不在 customize.sh 里直接装：Magisk 刷机脚本跑在独立的 mount namespace
# 里，那时 pm 与 system_server 的通信不一定通。所以刷机时先试一次，
# 失败就落一个标记，等开机后由 service.sh 再装（那时系统完全起来了）。

TILE_PKG=com.ruin.magpie.tile
TILE_APK_NAME=magpie-tile.apk

# 已装版本号；没装则输出空
tile_installed_code() {
  pm dump "$TILE_PKG" 2>/dev/null \
    | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' \
    | head -1
}

# 模块里那份 APK 的版本号（读 module.prop 旁边的小文件，见 build.sh）
tile_bundled_code() {
  _f="$1/tile-version"
  [ -f "$_f" ] && sed -n '1p' "$_f" | tr -dc '0-9'
}

# 安装/更新。$1 = 模块目录。返回 0 表示装好（或本来就够新）。
tile_install() {
  _mod="$1"
  _apk="$_mod/$TILE_APK_NAME"
  [ -f "$_apk" ] || { echo "找不到 $_apk"; return 1; }

  _want=$(tile_bundled_code "$_mod")
  _have=$(tile_installed_code)
  if [ -n "$_have" ] && [ -n "$_want" ] && [ "$_have" -ge "$_want" ] 2>/dev/null; then
    echo "已是最新（versionCode $_have）"
    return 0
  fi

  # -r 覆盖安装；-d 允许降级（用户从新版模块退回旧版时不该失败）
  if pm install -r -d "$_apk" 2>&1 | grep -q 'Success'; then
    echo "已安装 versionCode ${_want:-?}"
    return 0
  fi
  return 1
}

# 卸载
tile_uninstall() {
  pm uninstall "$TILE_PKG" 2>&1 | grep -q 'Success'
}
