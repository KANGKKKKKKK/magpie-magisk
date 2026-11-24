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

# 「桌面图标已隐藏」的意图记在这里，而不是 App 自己的 SharedPreferences。
#
# 为什么不用 App 的 prefs：App 数据在 CE 存储（/data/user/0/...），
# 模块脚本跑在 Magisk 的 mount namespace 里，看不到那条路径 ——
# 只有 /proc/<app pid>/root 下才能读到，而开机时 App 还没启动。
# 放模块自己的 run 目录，App 与脚本都能读写。
TILE_LAUNCHER_FLAG=".tile_launcher_hidden"

# 把「隐藏桌面图标」的意图在系统侧重新落实一次。
#
# 组件启用状态是系统侧的，会在覆盖安装、清除数据、部分系统更新、
# 以及模块更新时被重置回 default —— 隐藏过的图标就自己冒出来了。
# 用户隐藏图标后不会再打开 App，所以不能只靠 App 启动时对账，
# 开机（模块服务启动）时也要做一次。
tile_reconcile_launcher() {
  _run_dir=${1:-/data/adb/magpie/run}
  _flag="$_run_dir/$TILE_LAUNCHER_FLAG"
  [ -f "$_flag" ] || return 0
  _comp="$TILE_PKG/.Launcher"

  # 判断 alias 是否已经在禁用列表里。两个坑都是实测出来的：
  #
  #   1. pm dump 的 disabledComponents 段以**空行**结束，不是 "}"。
  #      用 "/disabledComponents/,/}/" 取范围会一路吃到后面某个 "}"，
  #      交给 grep 的内容远超这一段。
  #   2. 段里写的是完整类名 com.ruin.magpie.tile.Launcher，**不是**
  #      "com.ruin.magpie.tile/.Launcher"。拿后者去 grep 永远不匹配，
  #      于是每次开机都白跑一次 pm disable（幂等，所以症状看不出来）。
  #
  # 这里改成：截到空行为止 → 去首尾空白 → 整行字面匹配完整类名。
  if pm dump "$TILE_PKG" 2>/dev/null \
    | sed -n '/^[[:space:]]*disabledComponents:/,/^[[:space:]]*$/p' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -qxF "${TILE_PKG}.Launcher"; then
    return 0
  fi

  if pm disable --user 0 "$_comp" >/dev/null 2>&1; then
    echo "已按用户设置重新隐藏桌面图标"
    return 0
  fi
  return 1
}
