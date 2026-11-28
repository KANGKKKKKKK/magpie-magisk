#!/system/bin/sh
# 磁贴 App 的安装/卸载辅助，被 customize.sh 与 service.sh 共用。
#
# 为什么不在 customize.sh 里直接装：Magisk 刷机脚本跑在独立的 mount namespace
# 里，那时 pm 与 system_server 的通信不一定通。所以刷机时先试一次，
# 失败就落一个标记，等开机后由 service.sh 再装（那时系统完全起来了）。

TILE_PKG=com.ruin.magpie.tile
TILE_APK_NAME=magpie-tile.apk

# pm list 的包名参数是子串过滤。只认成功查询里完整的 package: 与 versionCode:
# 字段，不把近似包名、数字前缀或命令失败前的部分输出当成「已是最新」。
tile_installed_code() {
  _tile_list=$(pm list packages --show-versioncode "$TILE_PKG" 2>/dev/null) || return 1
  printf '%s\n' "$_tile_list" | awk -v pkg="package:$TILE_PKG" '
    { sub(/\r$/, "") }
    $1 == pkg {
      for (i = 2; i <= NF; i++) if ($i ~ /^versionCode:[0-9]+$/) {
        sub(/^versionCode:/, "", $i); print $i; exit
      }
    }'
}

# Release 的 tile-version 应恰好一行正整数，不能从「1.2」拼出 12。
tile_bundled_code() {
  [ -f "$1/tile-version" ] || return 1
  awk 'NR == 1 { sub(/\r$/, ""); code = $0 }
       END { if (NR != 1 || code !~ /^[1-9][0-9]*$/ || length(code) > 10 || code + 0 > 2147483647) exit 1
             print code }' "$1/tile-version"
}

# AOSP pm 的结果是 stdout 最后一条非空行；诊断里也可能有 Success 字样。
# 必须先等 pm 完成拿到它的退出码，不能只看管道末端 grep 的返回值。
tile_pm_success() {
  _tile_reply=$(pm "$@" 2>/dev/null) || return 1
  printf '%s\n' "$_tile_reply" | awk '{ sub(/\r$/, "") } NF { ok = (NF == 1 && $1 == "Success") } END { exit !ok }'
}

# 安装/更新。$1 = 模块目录。返回 0 表示装好（或本来就够新）。
tile_install() {
  _mod="$1"
  _apk="$_mod/$TILE_APK_NAME"
  [ -f "$_apk" ] || { echo "找不到 $_apk"; return 1; }

  _want=$(tile_bundled_code "$_mod") || _want=
  _have=$(tile_installed_code) || _have=
  if [ -n "$_have" ] && [ -n "$_want" ] && [ "$_have" -ge "$_want" ] 2>/dev/null; then
    echo "已是最新（versionCode $_have）"
    return 0
  fi

  # 查询不通不等于未安装。用户既已选装，仍可尝试 -r，但不要用 -d
  # 放行未知降级；也不代用户授予任何权限。
  if tile_pm_success install -r "$_apk"; then
    echo "已安装 versionCode ${_want:-?}"
    return 0
  fi
  return 1
}

# 卸载
tile_uninstall() {
  tile_pm_success uninstall "$TILE_PKG"
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

  # AOSP 只有非空列表才打印 disabledComponents，段尾不保证有空行。
  # 仅认目标 Package / User 0 / disabledComponents 内更深缩进的完整类名；
  # 下一个包、用户或同级小节必须先关闭状态，不能把 enabled 或其它用户算进来。
  # 先保存 pm 的退出码：失败或未知格式时宁可幂等补一次 disable，也不误报已隐藏。
  if _tile_dump=$(pm dump "$TILE_PKG" 2>/dev/null) &&
     printf '%s\n' "$_tile_dump" | awk -v pkg="$TILE_PKG" -v want="${TILE_PKG}.Launcher" '
      {
        indent = match($0, /[^[:space:]]/) - 1
        if ($0 ~ /^[[:space:]]*Package \[/) {
          name = $0
          sub(/^[[:space:]]*Package \[/, "", name)
          sub(/\].*$/, "", name)
          in_pkg = (name == pkg)
          pkg_indent = indent
          in0 = 0; disabled = 0
          next
        }
        if (!in_pkg) next
        if (indent < 0) { disabled = 0; next }
        if (indent <= pkg_indent) { in_pkg = 0; in0 = 0; disabled = 0; next }
        if ($0 ~ /^[[:space:]]*User [0-9]+:/) {
          in0 = ($2 == "0:")
          user_indent = indent
          disabled = 0
          next
        }
        if (!in0) next
        if (indent <= user_indent) { in0 = 0; disabled = 0; next }
        if ($0 ~ /^[[:space:]]*disabledComponents:[[:space:]]*$/) {
          disabled = 1; list_indent = indent; next
        }
        if (disabled && indent <= list_indent) disabled = 0
        if (disabled) {
          line = $0
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line == want) found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    '; then
    return 0
  fi

  if pm disable --user 0 "$_comp" >/dev/null 2>&1; then
    echo "已按用户设置重新隐藏桌面图标"
    return 0
  fi
  return 1
}
