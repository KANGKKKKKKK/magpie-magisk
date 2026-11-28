# customize.sh —— 刷入时由 Magisk / KernelSU / APatch 调用
# 只做权限与依赖检查，不改动模块文件内容，也不联网下载
# （刷入流程里没有可靠的交互终端，87 MB 的下载放到模块装好之后由用户确认触发）

ui_print "*******************************"
ui_print "  Magpie AI 网关 · Android 模块"
ui_print "*******************************"

# 目录 755，文件默认 644
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in action.sh service.sh uninstall.sh customize.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/scripts/magpie.config" 0 0 0600
[ -f "$MODPATH/system/bin/magpie" ] && set_perm "$MODPATH/system/bin/magpie" 0 0 0755

# 本模块只负责调度，不含 magpie 本体
# 路径按配置读，自定义过 magpie_path 的用户也能看到正确的结果
_CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$_CONF" ] || _CONF="$MODPATH/scripts/magpie.config"
# 语法错误的配置不 source：BusyBox ash 会因此整个退出（见 lib.sh magpie_conf_syntax_ok）
if [ -f "$_CONF" ] && ! sh -n "$_CONF" >/dev/null 2>&1; then
  ui_print "! 配置文件有语法错误，本次按默认值处理：$_CONF"
  ui_print "  修好后重启服务即可：sh -n $_CONF 可定位出错行"
else
  [ -f "$_CONF" ] && . "$_CONF" 2>/dev/null
fi
magpie_path=${magpie_path:-/data/adb/magpie}

# DNS：magpie 是不链接 libc 的 Go 静态 PIE，只认 /etc/resolv.conf。
# 这里按 MAGPIE_DNS 生成模块覆盖，开机后由 Magisk 挂成 /etc/resolv.conf；
# 老版本注入的 DNS_LOCAL_HOSTNAMES 是无效的（Go 与 magpie 都不读）。
# DNS 校验和下方的补装标记路径核验共用此库；没有改 DNS 也需要后者。
[ -f "$MODPATH/scripts/lib.sh" ] && . "$MODPATH/scripts/lib.sh" 2>/dev/null
_RESOLV="$MODPATH/system/etc/resolv.conf"
if [ -n "${MAGPIE_DNS:-}" ]; then
  command -v is_ip_addr >/dev/null 2>&1 || is_ip_addr() { [ -n "$1" ]; }

  mkdir -p "$MODPATH/system/etc"
  # 先写临时文件、确认里面真有 nameserver 再替换：
  # 配置写错时保留模块自带那份，别把能用的 DNS 覆盖成空的。
  _RESOLV_NEW="$_RESOLV.new"
  : > "$_RESOLV_NEW"
  _DNS_BAD=""
  for _ns in $MAGPIE_DNS; do
    if is_ip_addr "$_ns"; then
      echo "nameserver $_ns" >> "$_RESOLV_NEW"
    else
      _DNS_BAD="$_DNS_BAD $_ns"
    fi
  done
  echo "options timeout:2 attempts:2" >> "$_RESOLV_NEW"
  _DNS_BAD=${_DNS_BAD# }
  if grep -q '^nameserver ' "$_RESOLV_NEW" 2>/dev/null; then
    mv -f "$_RESOLV_NEW" "$_RESOLV" 2>/dev/null
    set_perm "$MODPATH/system/etc" 0 0 0755
    set_perm "$_RESOLV" 0 0 0644
    ui_print "- 上游 DNS：$MAGPIE_DNS（写入 /etc/resolv.conf 覆盖）"
    [ -n "$_DNS_BAD" ] && ui_print "! 这些项不是合法地址，已跳过：$_DNS_BAD"
  else
    rm -f "$_RESOLV_NEW" 2>/dev/null
    ui_print "! MAGPIE_DNS 里没有有效的 DNS 地址，保留模块自带的 /etc/resolv.conf"
  fi
fi
MAGPIE_BIN="$magpie_path/bin/magpie"
if [ -x "$MAGPIE_BIN" ]; then
  _ver=$(HOME="$magpie_path/data" "$MAGPIE_BIN" --version 2>/dev/null | head -1)
  if [ -n "$_ver" ]; then
    ui_print "- 已检测到本体：$_ver"
    ui_print "- 不会覆盖它；升级请用 su -c magpie update"
  else
    ui_print "! 本体存在但跑不起来：$MAGPIE_BIN"
    ui_print "! 可在管理器点 [执行] 重装"
  fi
else
  ui_print "- 尚未安装 magpie 本体（本模块不含本体）"
  ui_print "  安装方式：管理器点 [执行]，或执行"
  ui_print "    su -c sh /data/adb/modules/magpie/scripts/install.sh install --yes"
  ui_print "  本体就位前看门狗不会反复尝试启动"
fi

ui_print "- 开机后自动启动；管理器里点 [执行] 可启停"

# ---------- 磁贴 App（可选）----------
#
# 整次询问共用一个 15 秒窗口。只接受真实 EV_KEY 的首次 DOWN，忽略同步、
# 抬键、长按重复及其他输入。音量上下也可能不在同一个 event 设备上。
# 私有 FIFO 不记录输入；读端选中即退出，再回收本次启动的 getevent，不用
# 等下一条事件触发 SIGPIPE，也不向刷机 shell 发信号。
tile_read_choice() (
  umask 077
  _keys=$(mktemp -d "${TMPDIR:-$MODPATH}/.tile-keys.XXXXXX") || exit 1
  _reader=
  trap '
    if [ -n "$_reader" ]; then
      kill "$_reader" 2>/dev/null || :
      wait "$_reader" 2>/dev/null || :
    fi
    rm -f "$_keys/events"
    rmdir "$_keys"
  ' EXIT
  trap 'exit 1' HUP INT TERM
  mkfifo "$_keys/events" || exit 1
  getevent -ql >"$_keys/events" 2>/dev/null &
  _reader=$!
  # 键值只由受 timeout 管理的子 shell 读取和展开。
  # shellcheck disable=SC2016
  timeout 15 sh -c '
    while read -r type key state tail; do
      case "$type" in
        *:) type=$key; key=$state; state=$tail ;;  # 可选的设备名前缀
        *) [ -z "$tail" ] || continue ;;
      esac
      case "$type:$key:$state" in
        EV_KEY:KEY_VOLUMEUP:DOWN) echo install; exit 0 ;;
        EV_KEY:KEY_VOLUMEDOWN:DOWN) echo skip; exit 0 ;;
      esac
    done < "$1"
    exit 1' sh "$_keys/events"
)

# service.sh 只消费 run 下的单链接普通文件。保留用户的自定义目录，但不在
# 公共根、链接指向的目录、或特殊文件上写入。clear 不为未选装的人建目录。
tile_pending() (
  _mp=$(magpie_norm_path "$magpie_path") || exit 1
  case "$_mp" in ''|/|/data|/data/adb|/data/adb/modules|/data/adb/modules_update) exit 1 ;; esac
  _run="$magpie_path/run"
  magpie_path_unlinked "$_run" || exit 1
  umask 077
  case "$1" in
    clear) [ -e "$_run" ] || exit 0 ;;
    record) mkdir -p "$_run" || exit 1 ;;
    *) exit 1 ;;
  esac
  cd -P "$_run" && [ "$(pwd -P)" = "$_mp/run" ] || exit 1
  if [ -e .tile_pending ] || [ -L .tile_pending ]; then
    magpie_single_regular_file .tile_pending || exit 1
  fi
  if [ "$1" = clear ]; then
    rm -f .tile_pending
  else
    # mktemp 创建 0600 的普通文件；同目录原子替换，不截断或 chmod 旧目标。
    _tmp=$(mktemp ./.tile_pending.XXXXXX) || exit 1
    mv -fT "$_tmp" .tile_pending || { rm -f "$_tmp"; exit 1; }
  fi
)

install_tile_app() {
  _apk="$MODPATH/magpie-tile.apk"
  if [ ! -f "$_apk" ]; then
    return 0
  fi

  ui_print ""
  ui_print "*******************************"
  ui_print "  可选的配套 App"
  ui_print "*******************************"
  ui_print "- Magpie 磁贴：把「启动/停止」放进下拉控制中心"
  ui_print "  它不是 magpie 本体，也不代理流量；只是一个开关，"
  ui_print "  通过 root 调用本模块的启停脚本。不装也不影响网关运行。"
  ui_print ""

  _choice=
  if command -v getevent >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    ui_print "  音量键上 = 安装，音量键下 = 跳过（15 秒不按则本次跳过）"
    _choice=$(tile_read_choice 2>/dev/null) || _choice=
  else
    ui_print "! 无法限时读取音量键"
  fi
  case "$_choice" in
    skip)
      if tile_pending clear 2>/dev/null; then
        ui_print "- 已跳过，未保留开机补装请求。之后想装可手动打开 magpie-tile.apk。"
      else
        ui_print "! 本次已跳过，但未能清除旧补装标记；请检查 $magpie_path/run/.tile_pending"
      fi
      return 0 ;;
    install) ;;
    *)
      # 没有新选择：不调用 pm，不创建标记，也不替用户撤销先前的明确选装。
      ui_print "- 本次未选装：不立即安装，不新增补装；先前明确留下的请求不变。"
      ui_print "  之后想装：打开模块目录里的 magpie-tile.apk"
      return 0 ;;
  esac

  # 刷机时的 mount namespace 里 pm 不一定能用；不要把「已记录」说成「会装好」。
  # 在子 shell 里加载可选 helper：损坏的包也不能因 dot 的致命错误中止整个刷机。
  if ( [ -f "$MODPATH/scripts/tile-app.sh" ] && . "$MODPATH/scripts/tile-app.sh" &&
       tile_install "$MODPATH" ) >/dev/null 2>&1; then
    ui_print "- 磁贴 App 已安装"
    tile_pending clear 2>/dev/null || ui_print "! 未能清除旧补装标记；请检查 $magpie_path/run/.tile_pending"
    ui_print "  打开它授权一次 root，然后到「控制中心 → 编辑」把 Magpie 拖出来"
  elif tile_pending record 2>/dev/null; then
    ui_print "- 现在装不上，已记为「开机后再装」。"
    ui_print "  若开机后仍未装好，可手动打开模块目录里的 magpie-tile.apk。"
  else
    ui_print "! 现在装不上，也未能记录开机补装请求。"
    ui_print "  请手动打开模块目录里的 magpie-tile.apk 安装。"
  fi
}

install_tile_app
