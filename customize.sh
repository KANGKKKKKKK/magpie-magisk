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

# 本模块只负责调度，不含 magpie 本体
# 路径按配置读，自定义过 magpie_path 的用户也能看到正确的结果
_CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$_CONF" ] || _CONF="$MODPATH/scripts/magpie.config"
[ -f "$_CONF" ] && . "$_CONF" 2>/dev/null
magpie_path=${magpie_path:-/data/adb/magpie}

# DNS：magpie 是不链接 libc 的 Go 静态 PIE，只认 /etc/resolv.conf。
# 这里按 MAGPIE_DNS 生成模块覆盖，开机后由 Magisk 挂成 /etc/resolv.conf；
# 老版本注入的 DNS_LOCAL_HOSTNAMES 是无效的（Go 与 magpie 都不读）。
_RESOLV="$MODPATH/system/etc/resolv.conf"
if [ -n "${MAGPIE_DNS:-}" ]; then
  # 校验只用 lib.sh 那一份：刷入时 lib.sh 一定在包里。
  # 不在这里另写一套弱校验——看起来校验过、实际漏判，比明说没校验更坑。
  # shellcheck disable=SC1090
  [ -f "$MODPATH/scripts/lib.sh" ] && . "$MODPATH/scripts/lib.sh" 2>/dev/null
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
# 用音量键选择装不装。刷机流程里没有可靠 stdin，只能读按键设备。
# 读不到按键设备（getevent 不可用）时按「不装」处理：
# 用户没主动选过的东西，默认不该装。
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

  # 找按键设备：有 KEY_VOLUMEUP/KEY_VOLUMEDOWN 的 input 设备
  _ev=""
  for _d in /dev/input/event*; do
    [ -e "$_d" ] || continue
    if getevent -lp "$_d" 2>/dev/null | grep -q 'KEY_VOLUMEUP'; then
      _ev="$_d"
      break
    fi
  done

  if [ -z "$_ev" ]; then
    ui_print "! 读不到音量键，跳过（默认不装）"
    ui_print "  想装的话：刷完后打开模块目录里的 magpie-tile.apk 手动安装"
    return 0
  fi

  ui_print "  音量键上 = 安装，音量键下 = 跳过（15 秒不按则跳过）"
  _choice=""
  # 超时用 timeout 包住 getevent。
  # 不能写「后台 sleep 到点 kill $$」——子 shell 里的 $$ 是父 shell 的 pid，
  # 那样会把整个刷机脚本杀掉。
  _line=""
  if command -v timeout >/dev/null 2>&1; then
    _line=$(timeout 15 getevent -qlc 1 "$_ev" 2>/dev/null | head -1)
  else
    # 没有 timeout 就不读键：宁可默认跳过，也不要在刷机流程里无限等待
    ui_print "! 没有 timeout 命令，跳过按键选择"
  fi
  case "$_line" in
    *KEY_VOLUMEUP*DOWN*)   _choice=install ;;
    *KEY_VOLUMEDOWN*DOWN*) _choice=skip ;;
  esac

  if [ "$_choice" != "install" ]; then
    ui_print "- 已跳过。之后想装：打开模块目录里的 magpie-tile.apk"
    return 0
  fi

  # 刷机时的 mount namespace 里 pm 不一定能用，失败就交给开机后的 service.sh
  . "$MODPATH/scripts/tile-app.sh" 2>/dev/null
  if command -v tile_install >/dev/null 2>&1 && tile_install "$MODPATH" >/dev/null 2>&1; then
    ui_print "- 磁贴 App 已安装"
    ui_print "  打开它授权一次 root，然后到「控制中心 → 编辑」把 Magpie 拖出来"
  else
    ui_print "- 现在装不上，已记为「开机后再装」"
    ui_print "  重启后会自动装好；也可以手动打开模块目录里的 magpie-tile.apk"
    mkdir -p "$magpie_path/run" 2>/dev/null
    : > "$magpie_path/run/.tile_pending" 2>/dev/null
    chmod 600 "$magpie_path/run/.tile_pending" 2>/dev/null
  fi
}

install_tile_app
