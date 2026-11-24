#!/system/bin/sh
# Magpie for Android —— 模块的 [执行] 按钮
#
# 点一下就是一个音量键菜单，不进终端也能切网关、启停服务：
#   音量下 = 换一项，音量上 = 执行，60 秒不动自动退出。
#   音量键会顺带改媒体音量，退出时自动还原成进来时的值。
#
# 界面分两种，脚本自己判断：
#   · 终端里（Termux / adb shell，stdout 是 tty）：原地重画，整个菜单不动，
#     只有 ▸ 箭头换位置。
#   · Magisk 的 [执行] 窗口里（纯文本框，不认光标控制符）：只画一次菜单，
#     之后每按一次音量键追加一行「→ 4  停止」，执行动作后再整屏画一次。
#   想强制某种方式，可以设 MAGPIE_ACTION_TTY=1 或 MAGPIE_ACTION_NOTTY=1。
#   选 7 退出时，会顺手把 [执行] 那个文本框关掉，回到模块列表。
#
# 也能带参数直接调用（终端 / Tasker / 快捷方式）：
#   action.sh                     同 menu
#   action.sh status              接入信息（本机 + 局域网 + 进程号）
#   action.sh gateway             当前网关，以及配置文件里的两行监听地址
#   action.sh lan                 切到局域网：其他设备（平板）也能连
#   action.sh local               切回仅本机：外部连不上，最安全
#   action.sh start | stop | restart
#   action.sh panel               浏览器打开面板
#
# 切网关只改 magpie.config 里的 MAGPIE_ADDR / MAGPIE_WEB_ADDR 两行；
# 服务在跑就顺势重启一次让新地址生效。

# 模块目录。Magisk 用绝对路径调用；被相对路径调用时也能自己找对位置
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *)   MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/magpie
SERVICE="$MODDIR/scripts/magpie.service"

# 与 magpie.service 一致：补上 toybox/busybox 的路径，
# 否则在精简环境里 ip / pidof 可能找不到，局域网地址就探测不出来
export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

# 局域网地址、进程识别、地址解析，和 magpie.service / status.sh / doctor.sh 共用。
# 必须在读配置算端口之前 source：下面要用 addr_port / addr_host。
# lib.sh 万一缺失，这里补上最小实现，免得后面调用时报 not found。
_NETLIB="$MODDIR/scripts/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  lan_ip() { return 1; }
  magpie_main_pid() {
    for _p in $(pidof magpie 2>/dev/null); do
      if tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q -- ' serve'; then
        echo "$_p"; return 0
      fi
    done
    return 1
  }
  magpie_running() { magpie_main_pid >/dev/null 2>&1; }
  addr_host() { case "$1" in \[*\]:*) _h=${1#\[}; echo "${_h%%\]*}" ;; *:*) echo "${1%:*}" ;; *) echo "$1" ;; esac; }
  addr_port() { case "$1" in \[*\]:*) _p=${1##*\]:} ;; *:*) _p=${1##*:} ;; *) return 1 ;; esac; case "$_p" in ''|*[!0-9]*) return 1 ;; esac; echo "$_p"; }
  is_loopback_host() { _h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); case "$_h" in 127.*|localhost|::1|\[::1\]|::ffff:127.*) return 0 ;; esac; return 1; }
fi

CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

# 与 magpie.service 保持一致
magpie_path=${magpie_path:-/data/adb/magpie}
MAGPIE_ADDR=${MAGPIE_ADDR:-127.0.0.1:3425}

# 端口必须是 1..65535 的纯数字。配置写成 127.0.0.1（漏端口）时不能静默退回默认值：
# 那会让「点启动」看起来成功，实际连的是另一个端口，还拼出
# "http://127.0.0.1:127.0.0.1/v1" 这种链接。这里只记下错误，
# 由启动入口拒绝、由状态输出如实说明，不替用户猜。
API_PORT=$(addr_port "$MAGPIE_ADDR" 2>/dev/null)
WEB_ADDR=${MAGPIE_WEB_ADDR:-}
[ -n "$WEB_ADDR" ] || WEB_ADDR="$(addr_host "$MAGPIE_ADDR"):3430"
WEB_PORT=$(addr_port "$WEB_ADDR" 2>/dev/null)
ADDR_ERROR=""
if [ -z "$API_PORT" ]; then
  ADDR_ERROR="MAGPIE_ADDR=$MAGPIE_ADDR 的端口不可用（应为 主机:端口，1-65535；IPv6 用 [::1]:3425）"
elif [ -z "$WEB_PORT" ]; then
  ADDR_ERROR="MAGPIE_WEB_ADDR=$WEB_ADDR 的端口不可用（应为 主机:端口，1-65535）"
fi

# 只认 serve 主进程：MCP 子进程也叫 magpie，用 pidof 会误判
is_running() { magpie_running; }

sync_status() {
  [ -f "$MODDIR/scripts/status.sh" ] && sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
}

# 本体是否可用。点按是低频操作，跑一次 --version 的开销可以承担。
install_ready() {
  [ -f "$MODDIR/scripts/install.sh" ] || return 0   # 老版本没这个脚本，不拦
  _s=$(sh "$MODDIR/scripts/install.sh" status 2>/dev/null)
  case "$_s" in
    state=ready*) return 0 ;;
  esac
  return 1
}

# 局域网地址实时算，不读 run/lan.url —— 那是启动时的快照，
# WiFi 换过、热点开关过之后就可能指向一个已经不存在的地址。

panel_url() {
  _k=$(cat "$magpie_path/data/web.key" 2>/dev/null)
  if [ -n "$_k" ]; then
    echo "http://127.0.0.1:$WEB_PORT/?k=$_k"
  else
    echo "http://127.0.0.1:$WEB_PORT/"
  fi
}

# 接入信息。标签占 8 列（中文按两列算），值从第 10 列起；
# 「本机 / 平板」这层二级标签也停在同一列。
print_endpoints() {
  # 端口非法时不要打印任何地址：那些地址都是拼出来的假地址
  if [ -n "$ADDR_ERROR" ]; then
    echo " 配置    $ADDR_ERROR"
    echo " 文件    $CONF"
    echo " 进程    $(magpie_main_pid 2>/dev/null)"
    return 0
  fi
  _mode=$(gateway_mode)
  _lan_now=$(lan_ip)
  _open=""
  if [ "$_mode" = lan ] && [ -n "$_lan_now" ]; then _open=1; fi

  echo " 网关    本机 http://127.0.0.1:$API_PORT/v1"
  [ -n "$_open" ] && echo "         平板 http://$_lan_now:$API_PORT/v1"
  echo " 面板    本机 $(panel_url)"
  [ -n "$_open" ] && echo "         平板 http://$_lan_now:$WEB_PORT  （打开后要输访问密码）"
  echo " 进程    $(magpie_main_pid 2>/dev/null)"

  if [ "$_mode" = lan ]; then
    if [ -n "$_lan_now" ]; then
      echo " 提示    局域网已开放，其他设备可以连"
    else
      echo " 提示    局域网已开，但还没有可用地址（Wi-Fi 与热点都没开）"
    fi
  else
    echo " 提示    局域网未开放，只有本机能连"
  fi
}

# ---------- 网关监听地址 ----------
# addr_host / is_loopback_host 来自 lib.sh：IPv6 的 [::1]:3425 也能认出是本机
gateway_mode() {
  if is_loopback_host "$(addr_host "$MAGPIE_ADDR")"; then echo local; else echo lan; fi
}
gateway_host() { case "$1" in lan) echo 0.0.0.0 ;; *) echo 127.0.0.1 ;; esac }
gateway_other() { case "$(gateway_mode)" in lan) echo local ;; *) echo lan ;; esac }

# 短名，菜单里用
gateway_short() { case "$1" in lan) echo "局域网" ;; *) echo "仅本机" ;; esac; }
# 当前实际的监听地址：配置里可能不是 0.0.0.0 而是某个具体 IP，照实说
gateway_actual() { echo "$(gateway_short "$(gateway_mode)") $MAGPIE_ADDR"; }

# 把配置里的两个监听地址改成 $1 开头，其余行原样保留
write_conf_host() {
  _h="$1"
  _f="$CONF"
  [ -f "$_f" ] || { echo "找不到配置文件：$_f"; return 1; }
  _tmp="$_f.tmp.$$"
  sed -e "s|^MAGPIE_ADDR=.*|MAGPIE_ADDR=\"$_h:$API_PORT\"|" \
      -e "s|^MAGPIE_WEB_ADDR=.*|MAGPIE_WEB_ADDR=\"$_h:$WEB_PORT\"|" "$_f" > "$_tmp" 2>/dev/null
  [ -s "$_tmp" ] || { rm -f "$_tmp"; echo "写配置失败：sed 没有产出内容"; return 1; }
  grep -q '^MAGPIE_ADDR=' "$_tmp"     || printf 'MAGPIE_ADDR="%s:%s"\n' "$_h" "$API_PORT" >> "$_tmp"
  grep -q '^MAGPIE_WEB_ADDR=' "$_tmp" || printf 'MAGPIE_WEB_ADDR="%s:%s"\n' "$_h" "$WEB_PORT" >> "$_tmp"
  # cat 覆盖而不是 mv：保留原文件的 inode 与权限
  cat "$_tmp" > "$_f" || { rm -f "$_tmp"; echo "写配置失败：无法写入 $_f"; return 1; }
  rm -f "$_tmp"
  MAGPIE_ADDR="$_h:$API_PORT"
  WEB_ADDR="$_h:$WEB_PORT"
  return 0
}

# 其他设备（平板上的 Eta 之类）该填什么
device_hint() {
  _lan=$(lan_ip)
  [ -n "$_lan" ] || return 0
  echo
  echo "其他设备（平板 / 电脑）这样填："
  echo "  接口  http://$_lan:$API_PORT/v1"
  echo "  密钥  面板 › 网关 › 调用密钥，用名为 Magpie 的那把"
}

# $1 = 轮数，每轮 0.25 秒
wait_ready() {
  _i=0
  _lim=${1:-40}
  while [ "$_i" -lt "$_lim" ]; do
    is_running && return 0
    sleep 0.25
    _i=$((_i + 1))
  done
  return 1
}

set_gateway() {
  _to="$1"
  # 端口读不出来时不能改配置：会写出 "0.0.0.0:" 这种半截地址
  if [ -n "$ADDR_ERROR" ]; then
    echo "配置有问题，先改好再切网关："
    echo "  $ADDR_ERROR"
    echo "  配置文件 $CONF"
    return 1
  fi
  if [ "$_to" = "$(gateway_mode)" ]; then
    echo "网关现在就是「$(gateway_actual)」，不用改。"
    return 0
  fi
  write_conf_host "$(gateway_host "$_to")" || return 1
  echo "已切到「$(gateway_actual)」，配置里这两行改了："
  grep -nE '^MAGPIE_ADDR=|^MAGPIE_WEB_ADDR=' "$CONF" | sed 's/^/  /'

  if ! is_running; then
    echo
    echo "magpie 没在运行，下次启动时生效。"
    sync_status
    return 0
  fi

  echo
  echo "正在重启，让新地址生效 ..."
  sh "$SERVICE" restart >/dev/null 2>&1
  if ! wait_ready 60; then
    echo "重启后没能起来。日志末尾："
    tail -n 20 "$magpie_path/run/magpie.log" 2>/dev/null
    sync_status
    return 1
  fi

  echo "重启完成。"
  echo
  print_endpoints
  [ "$_to" = lan ] && device_hint
  sync_status
  return 0
}

do_start() {
  # 端口非法时不启动：让服务用默认端口跑起来，用户只会看到「已启动」然后连不上，
  # 比直接报错更难查。
  if [ -n "$ADDR_ERROR" ]; then
    echo "配置有问题，先改好再启动："
    echo "  $ADDR_ERROR"
    echo "  配置文件 $CONF"
    return 1
  fi
  echo "启动中 ..."
  sh "$SERVICE" start
  if wait_ready 80; then
    echo "已启动。"
    echo
    print_endpoints
  else
    echo "没能启动。日志末尾："
    tail -n 20 "$magpie_path/run/magpie.log" 2>/dev/null
  fi
  sync_status
}

do_stop() {
  echo "停止中 ..."
  sh "$SERVICE" stop
  _i=0
  while [ "$_i" -lt 25 ]; do
    is_running || break
    sleep 0.2
    _i=$((_i + 1))
  done
  if is_running; then
    echo "没能停掉，进程还在。日志末尾："
    tail -n 20 "$magpie_path/run/magpie.log" 2>/dev/null
  else
    echo "已停止。"
  fi
  sync_status
}

do_restart() {
  if [ -n "$ADDR_ERROR" ]; then
    echo "配置有问题，先改好再重启："
    echo "  $ADDR_ERROR"
    echo "  配置文件 $CONF"
    return 1
  fi
  echo "重启中 ..."
  sh "$SERVICE" restart >/dev/null 2>&1
  if wait_ready 80; then
    echo "已重启。"
    echo
    print_endpoints
  else
    echo "没能重启。日志末尾："
    tail -n 20 "$magpie_path/run/magpie.log" 2>/dev/null
  fi
  sync_status
}

open_panel() {
  _url=$(panel_url)
  echo "面板  http://127.0.0.1:$WEB_PORT"
  # 指定 user 0，否则 root shell 下 am 可能因用户不确定而失败
  am start -a android.intent.action.VIEW -d "$_url" --user 0 2>/dev/null \
    || am start -a android.intent.action.VIEW -d "$_url" 2>/dev/null \
    || echo "没能自动打开，请手动访问上面的地址。"
}

# ---------- 音量键 ----------
KEYLOG=""
KEYPID=""
KEYN=0
VOL_SAVED=""

keys_available() { command -v getevent >/dev/null 2>&1; }

start_keys() {
  # 用 magpie 自己的 run 目录：不依赖 TMPDIR（Magisk 与应用里各不相同）
  mkdir -p "$magpie_path/run" 2>/dev/null
  # 上一次被强杀留下的按键日志：对应 PID 已经不在了就清掉
  for _f in "$magpie_path"/run/magpie-keys.*; do
    [ -f "$_f" ] || continue
    _p=${_f##*.}
    case "$_p" in ''|*[!0-9]*) rm -f "$_f" 2>/dev/null; continue ;; esac
    kill -0 "$_p" 2>/dev/null || rm -f "$_f" 2>/dev/null
  done
  KEYLOG="$magpie_path/run/magpie-keys.$$"
  : > "$KEYLOG" 2>/dev/null || return 1
  getevent -lq > "$KEYLOG" 2>/dev/null &
  KEYPID=$!
  KEYN=0
  # getevent 立刻退出（没有权限、设备不支持）时不要傻等 60 秒
  sleep 0.3
  if ! kill -0 "$KEYPID" 2>/dev/null; then
    KEYPID=""
    rm -f "$KEYLOG" 2>/dev/null
    KEYLOG=""
    return 1
  fi
  return 0
}

stop_keys() {
  [ -n "$KEYPID" ] && kill "$KEYPID" 2>/dev/null
  KEYPID=""
  [ -n "$KEYLOG" ] && rm -f "$KEYLOG" 2>/dev/null
  KEYLOG=""
}

# read_key <秒>：结果写进 KEYLAST（up | down | timeout）
# 不能 echo + $( ) 取值：命令替换是子 shell，KEYN 的推进不会带回来，
# 结果同一次按键会被反复读到。
# 只认 DOWN 事件，避免同一次按压的 UP 被算成第二次。
# 超时按真实时间算（每秒校一次表）：只数 sleep 次数的话，
# wc/grep 的耗时会让「60 秒」拖到一分半。
read_key() {
  KEYLAST=""
  _end=$(( $(date +%s) + $1 ))
  _tick=0
  while :; do
    _tot=$(wc -l < "$KEYLOG" 2>/dev/null | tr -d ' ')
    [ -n "$_tot" ] || _tot=0
    if [ "$_tot" -gt "$KEYN" ]; then
      _new=$(tail -n +"$((KEYN + 1))" "$KEYLOG" 2>/dev/null)
      KEYN="$_tot"
      # 值那一列必须真的是 DOWN：KEY_VOLUMEDOWN 这串本身就含 DOWN，
      # 只按子串匹配会把松开（UP）也当成一次按下。
      _k=""
      if echo "$_new" | grep -qE 'KEY_VOLUMEUP[[:space:]]+DOWN|[[:space:]]0073[[:space:]]+00000001'; then
        _k=up
      elif echo "$_new" | grep -qE 'KEY_VOLUMEDOWN[[:space:]]+DOWN|[[:space:]]0072[[:space:]]+00000001'; then
        _k=down
      fi
      if [ -n "$_k" ]; then
        sleep 0.1
        KEYN=$(wc -l < "$KEYLOG" 2>/dev/null | tr -d ' ')
        KEYLAST="$_k"
        return 0
      fi
    fi
    _tick=$((_tick + 1))
    if [ "$_tick" -ge 10 ]; then
      _tick=0
      [ "$(date +%s)" -lt "$_end" ] || break
    fi
    sleep 0.1
  done
  KEYLAST=timeout
  return 0
}

save_vol() {
  VOL_SAVED=$(cmd media_session volume --stream 3 --get 2>/dev/null | sed -n 's/.*volume is \([0-9]*\).*/\1/p')
}
restore_vol() {
  [ -n "$VOL_SAVED" ] && cmd media_session volume --stream 3 --set "$VOL_SAVED" >/dev/null 2>&1
}

# ---------- 菜单 ----------
ITEMS=7
SEL=2
# 终端（Termux / adb shell）里可以原地重画，Magisk 的文本框里不行：
# 它只逐行追加文本，不认光标控制符，硬写 ANSI 只会看到一串乱码。
UI_TTY=""
if [ -n "${MAGPIE_ACTION_TTY:-}" ]; then
  UI_TTY=1                       # 测试用：强制当作终端
elif [ -z "${MAGPIE_ACTION_NOTTY:-}" ] && [ -t 1 ]; then
  UI_TTY=1
fi
UI_DRAWN=""

# 菜单每一项叫什么，画菜单和「只报选中项」共用一份
item_name() {
  case "$1" in
    1) echo "切到「$(gateway_short "$(gateway_other)")」" ;;
    2) echo "查看接入信息" ;;
    3) echo "重启" ;;
    4) echo "停止" ;;
    5) echo "启动" ;;
    6) echo "打开面板" ;;
    7) echo "退出" ;;
  esac
}

# 一行菜单项：选中的前面带 ▸，其余补同样宽的空格
row() {
  if [ "$1" = "$SEL" ]; then
    printf ' ▸ %s  %s\n' "$1" "$2"
  else
    printf '   %s  %s\n' "$1" "$2"
  fi
}

SEP32='────────────────────────────────'
menu_body() {
  _cur=$(gateway_mode)
  echo
  echo "───────────  Magpie  ───────────"
  if is_running; then echo " 状态  运行中"
  else echo " 状态  已停止"; fi
  case "$_cur" in
    lan)
      _lan=$(lan_ip)
      echo " 网关  局域网 · 其他设备可连接"
      echo " 地址  ${_lan:-无（Wi-Fi 与热点都没开）}"
      ;;
    *)
      echo " 网关  仅本机 · 其他设备连不上"
      ;;
  esac
  echo "$SEP32"
  _n=1
  while [ "$_n" -le "$ITEMS" ]; do
    row "$_n" "$(item_name "$_n")"
    _n=$((_n + 1))
  done
  echo "$SEP32"
  echo " 音量下 换一项 · 音量上 执行"
  echo " 60 秒没按键就自动退出"
}

draw_menu() {
  # 终端里先把光标送回左上角再重画，视觉上就是「同一个菜单，只有箭头动」
  if [ -n "$UI_TTY" ] && [ -n "$UI_DRAWN" ]; then
    printf '\033[H\033[2J'
  fi
  menu_body
  UI_DRAWN=1
}

# 非终端只能追加：每次换项只报一行，不整屏重画
show_sel() {
  printf ' → %s  %s\n' "$SEL" "$(item_name "$SEL")"
}

run_item() {
  case "$1" in
    1) set_gateway "$(gateway_other)" ;;
    2) echo; print_endpoints; [ "$(gateway_mode)" = lan ] && device_hint ;;
    3) do_restart ;;
    4) do_stop ;;
    5) do_start ;;
    6) open_panel ;;
    7) CLOSE_AFTER=1; return 1 ;;
  esac
  return 0
}

# ---------- 收尾：从 Magisk 的 [执行] 窗口回到模块列表 ----------
# Magisk 跑完 action.sh 不会自己关掉那个文本框，页面就停在那儿。
# 主动按一次返回键把浮层关掉，就回到模块列表了。
# 只在「确实是在模块管理器里跑」时才按：终端、adb、别的 App 里跑绝不动手。
MGR_PKGS="com.topjohnwu.magisk me.weishu.kernelsu me.bmax.apatch com.dergoogler.mmrl com.fox2code.mmm"

is_mgr_pkg() {
  for _m in $MGR_PKGS; do
    [ "$1" = "$_m" ] && return 0
  done
  return 1
}

# 前台是哪个包
fg_pkg() {
  dumpsys window 2>/dev/null | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^ /}]*\)\/.*/\1/p' | head -1
}

# 自己是不是被模块管理器拉起来的：沿父进程往上找 5 层。
# 只看每个进程的第一个参数（进程名 / 可执行文件路径），
# 不看整条命令行——命令行里的文字（比如 pkill com.topjohnwu.magisk）会误判。
inside_manager() {
  _p=$$
  _i=0
  while [ "$_i" -lt 5 ]; do
    _nm=$(tr '\0' '\n' < "/proc/$_p/cmdline" 2>/dev/null | head -1)
    case "$_nm" in
      */*) _nm=${_nm##*/} ;;
    esac
    is_mgr_pkg "$_nm" && return 0
    _p=$(awk '{print $4}' "/proc/$_p/stat" 2>/dev/null)
    case "$_p" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_p" -le 1 ] && return 1
    _i=$((_i + 1))
  done
  return 1
}

close_console() {
  [ -n "$UI_TTY" ] && return 0        # 终端里不按，免得关掉别人的界面
  if ! inside_manager && ! is_mgr_pkg "$(fg_pkg)"; then
    return 0                          # 不在管理器里跑，也不在它前台上：不动
  fi
  command -v input >/dev/null 2>&1 || return 0
  input keyevent 4 >/dev/null 2>&1    # KEYCODE_BACK：关掉浮层，露出模块列表
  sleep 0.4
  return 0
}

# 读不到音量键时的退路：沿用老版的一键启停，别让人卡在这里
legacy_toggle() {
  if is_running; then
    print_endpoints
    echo
    do_stop
    echo
    echo "下次点 [执行] 会重新启动。"
  else
    do_start
    echo
    open_panel
  fi
}

menu() {
  # 本体没就绪：[执行] 变成安装入口，不再是菜单
  if ! install_ready; then
    _st=$(sh "$MODDIR/scripts/install.sh" status 2>/dev/null | sed -n 's/^state=\([a-z]*\).*/\1/p')
    case "$_st" in
      broken) echo "Magpie 本体在，但跑不起来。" ;;
      *)      echo "还没装 Magpie 本体。" ;;
    esac
    echo
    # 无 --yes：第一次点按只打印方案，窗口内再点一次才真正下载
    sh "$MODDIR/scripts/install.sh" install
    # 安装器失败时必须把失败码传出去：吞掉它，管理器会把失败显示成成功
    _rc=$?
    echo
    sync_status
    exit "$_rc"
  fi

  save_vol
  if ! keys_available || ! start_keys; then
    echo "读不到音量键（getevent 用不了），这次按老办法一键启停。"
    echo "想用菜单，也可以在终端里跑：sh <本文件> status | lan | local"
    restore_vol
    legacy_toggle
    exit 0
  fi
  trap 'stop_keys; restore_vol' EXIT INT TERM HUP

  while :; do
    # 终端里每次原地重画（箭头移动）；Magisk 文本框里只在开头和动作之后整屏画
    if [ -n "$UI_TTY" ] || [ -z "$UI_DRAWN" ]; then
      draw_menu
    fi
    read_key 60
    case "$KEYLAST" in
      down)
        SEL=$((SEL + 1))
        [ "$SEL" -gt "$ITEMS" ] && SEL=1
        [ -z "$UI_TTY" ] && show_sel
        ;;
      up)
        UI_DRAWN=""        # 动作的输出要看得见，之后整屏重画一次
        if ! run_item "$SEL"; then break; fi
        ;;
      timeout)
        echo
        echo "60 秒没按键，退出。"
        break
        ;;
    esac
  done

  stop_keys
  restore_vol
  trap - EXIT INT TERM HUP
  [ -n "$CLOSE_AFTER" ] && close_console
  exit 0
}

# 自测用：MAGPIE_ACTION_LIB=1 时只加载函数，不执行主流程
if [ "${MAGPIE_ACTION_LIB:-}" = "1" ]; then
  # 被 source 时 return 生效、脚本到此为止；被直接执行时 return 会失败，
  # 由 || exit 0 兜住。两种调用方式都要能正常结束，所以两句都得写。
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

case "$1" in
  ""|menu)
    menu
    ;;
  status)
    print_endpoints
    [ "$(gateway_mode)" = lan ] && device_hint
    exit 0
    ;;
  gateway)
    echo "当前网关  $(gateway_actual)"
    echo "配置文件  $CONF"
    grep -nE '^MAGPIE_ADDR=|^MAGPIE_WEB_ADDR=' "$CONF" 2>/dev/null | sed 's/^/  /'
    exit 0
    ;;
  lan|local)
    set_gateway "$1"
    exit $?
    ;;
  start|stop|restart)
    install_ready || { echo "本体还没装好：先点模块的 [执行] 走一遍安装。"; exit 1; }
    # 与菜单里选同一项时输出一致，退出码仍然反映最终状态
    "do_$1"
    case "$1" in
      stop) is_running && exit 1 || exit 0 ;;
      *)    is_running && exit 0 || exit 1 ;;
    esac
    ;;
  panel)
    open_panel
    exit 0
    ;;
  *)
    echo "点模块的 [执行] 就是音量键菜单；也可以带参数调用："
    echo "  status      接入信息"
    echo "  gateway     当前网关与配置里的两行"
    echo "  lan         切到局域网（其他设备可连接）"
    echo "  local       切回仅本机"
    echo "  start       启动"
    echo "  stop        停止"
    echo "  restart     重启"
    echo "  panel       打开面板"
    echo "用法：sh <本文件> <命令>"
    exit 1
    ;;
esac
