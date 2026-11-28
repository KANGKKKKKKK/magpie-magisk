#!/system/bin/sh
# 公共工具：局域网地址探测 + magpie 进程识别。
# 被 magpie.service / status.sh / action.sh / doctor.sh / service.sh 共用。
# 只定义函数，不做任何动作。

# ---------- 内核文件锁 ----------
# 只选择支持 FD flock 的实现；没有 flock 时调用方必须失败关闭。
# 锁文件必须持久保留，绝不能 unlink/替换，否则等待者会锁住不同 inode。
magpie_pick_flock() {
  MAGPIE_FLOCK_CMD=""; MAGPIE_FLOCK_BUSYBOX=""
  if command -v flock >/dev/null 2>&1; then
    MAGPIE_FLOCK_CMD=$(command -v flock)
    return 0
  fi
  for _flock_bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$_flock_bb" ] && "$_flock_bb" flock --help >/dev/null 2>&1; then
      MAGPIE_FLOCK_CMD="$_flock_bb"; MAGPIE_FLOCK_BUSYBOX=1
      return 0
    fi
  done
  return 1
}

magpie_flock() {
  [ -n "${MAGPIE_FLOCK_CMD:-}" ] || return 1
  _flock_fd=${2:-}
  [ -z "${MAGPIE_FLOCK_BUSYBOX:-}" ] || set -- flock "$@"
  # Android mksh 的 exec N>>file 默认 CLOEXEC，函数调用处 N>&N 也不够；
  # 必须在真正外部 flock 命令上重定向 FD。只支持 shell 的单数字 FD，
  # 用明确分支而不是对调用参数 eval，避免把锁操作变成代码执行入口。
  case "$_flock_fd" in
    0) "$MAGPIE_FLOCK_CMD" "$@" 0>&0 ;;
    1) "$MAGPIE_FLOCK_CMD" "$@" 1>&1 ;;
    2) "$MAGPIE_FLOCK_CMD" "$@" 2>&2 ;;
    3) "$MAGPIE_FLOCK_CMD" "$@" 3>&3 ;;
    4) "$MAGPIE_FLOCK_CMD" "$@" 4>&4 ;;
    5) "$MAGPIE_FLOCK_CMD" "$@" 5>&5 ;;
    6) "$MAGPIE_FLOCK_CMD" "$@" 6>&6 ;;
    7) "$MAGPIE_FLOCK_CMD" "$@" 7>&7 ;;
    8) "$MAGPIE_FLOCK_CMD" "$@" 8>&8 ;;
    9) "$MAGPIE_FLOCK_CMD" "$@" 9>&9 ;;
    *) return 2 ;;
  esac
}

# ---------- 监听地址 ----------
#
# 配置里的 MAGPIE_ADDR / MAGPIE_WEB_ADDR 形如 "host:port"。
# IPv6 必须写方括号（[::1]:3425），否则最后一个冒号分不清是端口还是地址的一部分。

# 取主机部分，不校验；IPv6 会去掉方括号（返回 ::1 而不是 [::1]）
addr_host() {
  case "$1" in
    \[*\]:*) _h=${1#\[}; _h=${_h%%\]:*} ;;
    \[*\])   _h=${1#\[}; _h=${_h%\]} ;;
    *:*:*)   _h=$1 ;;    # 裸 IPv6 保留原文，不把末段当成端口
    *:*)     _h=${1%:*} ;;
    *)       _h=$1 ;;
  esac
  printf '%s\n' "$_h"
}

# 取端口；地址结构不对或端口不是 1..65535 的纯数字时返回 1，不打印任何东西。
# 调用方必须按失败处理：静默退回默认端口会把配置错误藏起来，
# 拼出 "http://127.0.0.1:0.0.0.0/v1" 这种链接、写出非法 JSON。
addr_port() (
  case "$1" in
    \[*\]:*)
      _ph=${1#\[}; _ph=${_ph%%\]:*}; _p=${1#*\]:}
      # 监听地址可带 %wlan0 等 zone；只把地址本体交给 DNS 共用的 IPv6 校验器。
      case "$_ph" in *%*) case "${_ph#*%}" in ''|*[!a-zA-Z0-9_.-]*) return 1 ;; esac ;; esac
      is_ipv6_addr "${_ph%%\%*}" || return 1 ;;
    *:*:*|*\[*|*\]*|*[[:space:]]*) return 1 ;;
    *:*) _p=${1#*:} ;;   # 未加括号时只有一个冒号；保留 hostname 及空主机
    *)   return 1 ;;
  esac
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  case "$_p" in 0*) return 1 ;; esac          # 端口 0、前导零都当非法
  [ "${#_p}" -le 5 ] || return 1
  [ "$_p" -le 65535 ] || return 1
  echo "$_p"
)

# 回环地址？认 127/8、localhost、::1（含方括号与完整写法）。
# 空主机（":3425"）表示监听全部网卡，不算回环。
is_loopback_host() (
  _h=$1
  case "$_h" in \[*:*\]) _h=${_h#\[}; _h=${_h%\]} ;; esac
  case "$_h" in
    [Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]|::1|0:0:0:0:0:0:0:1) return 0 ;;
    ::[fF][fF][fF][fF]:127.*) _h=${_h#::????:} ;;
    127.*) ;;
    *) return 1 ;;
  esac
  # 127.example 也可能是主机名；点分写法（含 IPv4-mapped）必须完整落在 127/8。
  is_ipv4_addr "$_h"
)

# ---------- 路径 ----------

# 归一化一个绝对路径，用于「这个路径能不能删 / 能不能往里装」这类判断。
#
# 为什么要单独做：直接拿原串去 case 匹配会被一个多余的斜杠绕过 ——
# `/data` 在白名单里，`/data/` 不在，于是落到「是绝对路径就放行」那一支。
# 触发只需要配置里写成 magpie_path="/data/"，后果是 rm -rf /data。
#
# 规则：剥掉所有末尾斜杠；"//" 折叠成 "/"；剥完是空串则输出 "/"。
magpie_norm_path() {
  _p=$1
  case "$_p" in
    /*) ;;
    *) return 1 ;;
  esac

  # 含 . 或 .. 的路径必须先解析成真实路径再判定。
  #
  # 只做字符串归一化是不够的：case 匹配发生在原始串上，而 rm -rf 执行时
  # 会做一次 POSIX 路径解析。"/data/../data" 在白名单里匹配不上，于是被放行，
  # 但 rm -rf 实际删的是 /data。
  #
  # 用纯 shell 逐段解析，不依赖 readlink -m：
  # Android 上的 readlink 来自 busybox，只支持 -f（要求路径存在），
  # 没有 -m。用 -f 对不存在的路径会失败，退回 cd+pwd 又会被 .. 带偏。
  case "$_p" in
    */.|*/..|*/./*|*/../*|.|..)
      _rest=$_p
      _out=""
      while [ -n "$_rest" ]; do
        # 跳过开头的斜杠，取第一段
        _rest=${_rest#/}
        [ -n "$_rest" ] || break
        case "$_rest" in
          */*) _seg=${_rest%%/*}; _rest=${_rest#*/} ;;
          *)   _seg=$_rest; _rest="" ;;
        esac
        case "$_seg" in
          ''|.) continue ;;
          ..)
            # 退一级；已经在根就停在根
            _out=${_out%/*}
            ;;
          *)
            _out="$_out/$_seg"
            ;;
        esac
      done
      [ -n "$_out" ] || _out="/"
      _p=$_out
      ;;
  esac

  # 折叠重复斜杠
  while :; do
    case "$_p" in
      *//*) _p=$(printf '%s' "$_p" | sed 's|//*|/|g') ;;
      *) break ;;
    esac
  done
  # 剥末尾斜杠；根目录剥完是空串，补回 "/"
  while [ "${_p%/}" != "$_p" ]; do
    _p=${_p%/}
  done
  [ -n "$_p" ] || _p="/"
  echo "$_p"
}

# 历史白名单，仅用于只读识别旧安装位置；不再是允许删除数据的判据。
# 新安装使用下面更窄的持久目录白名单，卸载不递归删除数据。
magpie_path_cleanable() {
  _c=$(magpie_norm_path "$1" 2>/dev/null) || return 1

  case "$_c" in
    /data/adb/magpie|/data/adb/magpie/*) return 0 ;;
    /data/adb/modules/magpie|/data/adb/modules/magpie/*) return 0 ;;
  esac

  return 1
}

# 持久数据只能放在可跨模块更新/移除保留的目录。符号链接另由安装器拒绝。
magpie_path_installable() (
  _pi=$(magpie_norm_path "$1" 2>/dev/null) || exit 1
  case "$_pi" in /data/adb/magpie|/data/adb/magpie/*) exit 0 ;; *) exit 1 ;; esac
)

# 判断旧布局是否在管理器可能整棵替换的模块目录里。对已有路径也检查物理位置。
magpie_path_in_module_tree() (
  _pt_path=$(magpie_norm_path "$1" 2>/dev/null) || exit 1
  _pt_module=$(magpie_norm_path "$2" 2>/dev/null) || exit 1
  case "$_pt_path" in
    "$_pt_module"|"$_pt_module"/*|/data/adb/modules|/data/adb/modules/*|/data/adb/modules_update|/data/adb/modules_update/*) exit 0 ;;
  esac
  _pt_real=$(readlink -f "$_pt_path" 2>/dev/null) || exit 1
  _pt_mod_real=$(readlink -f "$_pt_module" 2>/dev/null) || _pt_mod_real=$_pt_module
  case "$_pt_real" in
    "$_pt_mod_real"|"$_pt_mod_real"/*|/data/adb/modules|/data/adb/modules/*|/data/adb/modules_update|/data/adb/modules_update/*) exit 0 ;;
    *) exit 1 ;;
  esac
)

# ---------- 局域网地址 ----------

# 可用作「别的设备能连上」的地址吗？
# 排除：
#   - 回环 127/8、未指定 0.0.0.0
#   - 链路本地 169.254/16
#   - mihomo / Clash 的 fake-ip 198.18.0.0/15
#   - 运营商级 NAT 100.64.0.0/10（只有运营商内网可达，报出去没人连得上）
is_usable_lan_ip() {
  case "$1" in
    ''|0.0.0.0|127.*|169.254.*|198.18.*|198.19.*) return 1 ;;
    100.*)
      _o2=${1#100.}; _o2=${_o2%%.*}
      [ "$_o2" -ge 64 ] 2>/dev/null && [ "$_o2" -le 127 ] 2>/dev/null && return 1
      ;;
  esac
  return 0
}

# 打一个可用地址，没有则返回 1。
# 优先 WiFi / 热点 / USB，这些才是别的设备能直接连上的；
# 再退回其它网卡，但跳过移动数据（ccmni/rmnet）和 clat。
#
# 只调用一次 ip：看门狗每轮都会走到这里，以前每块网卡各 fork 一次 ip + sed。
lan_ip() {
  _li_rows=$(ip -4 -o addr show 2>/dev/null |
    sed -n 's/^[0-9]*: *\([^ ]*\) .*inet \([0-9.]*\)\/.*/\1 \2/p')
  [ -n "$_li_rows" ] || return 1
  for _if in wlan0 wlan1 ap0 usb0 rndis0 eth0 '*'; do
    while read -r _li_if _a; do
      [ -n "$_a" ] || continue
      _li_if=${_li_if%%@*}
      if [ "$_if" = '*' ]; then
        case "$_li_if" in lo|ccmni*|rmnet*|clat*) continue ;; esac
      elif [ "$_li_if" != "$_if" ]; then
        continue
      fi
      is_usable_lan_ip "$_a" && { echo "$_a"; return 0; }
    done <<LANIP
$_li_rows
LANIP
  done
  return 1
}

# ---------- 进程 ----------
#
# magpie 主进程是 `magpie serve --web=...`，但它还会拉起同名的子进程：
#   magpie mcp vision / mcp search / mcp image
# `pidof magpie` 一次返回全部，head -1 拿到的可能是子进程而不是网关本身。
# 所以凡是「服务是否在跑」「该杀哪个」的判断，都必须先认出主进程。

# 同时核对本体与 argv[1]，不能只在整条命令行里搜 serve / mcp：
# `magpie update --note 'serve ...'` 仍是普通 CLI。枚举和发信号共用此判断。
# BIN 仅服务控制器有；status / doctor / 看门狗按调用时的 magpie_path 取本体，
# 两者都未设置才用默认路径。可显式传第三个参数，且不要求本体文件仍存在。
magpie_pid_command() (
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in serve|mcp) ;; *) return 1 ;; esac
  _mp_bin=${3:-${BIN:-${magpie_path:-/data/adb/magpie}/bin/magpie}}
  _mp_exe=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
  _mp_real=$(readlink -f "$_mp_bin" 2>/dev/null) || _mp_real=$_mp_bin
  # 自定义路径可含符号链接；覆盖更新后的进程可能仍持有旧 inode。
  case "$_mp_exe" in
    "$_mp_bin"|"$_mp_bin (deleted)"|"$_mp_real"|"$_mp_real (deleted)") ;;
    *) return 1 ;;
  esac
  # 先把原有换行转成非分隔符，只有 NUL 才能变成 argv 边界；否则 argv[0]
  # 或 CLI 参数里的换行也会冒充 argv[1]。不做 shell 分词或 eval。
  _mp_cmd=$(tr '\000\n' '\n\001' < "/proc/$1/cmdline" 2>/dev/null) || return 1
  case "$_mp_cmd" in
    *'
'*) _mp_args=${_mp_cmd#*'
'} ;;
    *) return 1 ;;
  esac
  [ "${_mp_args%%'
'*}" = "$2" ]
)

# 只枚举指定子命令；伪候选、异路径同名进程、已退出/换身份的 PID 均跳过。
# first 只影响数量，不改变身份标准。子 shell 不污染调用者的循环变量。
magpie_command_pids() (
  case "$1" in serve|mcp) ;; *) return 1 ;; esac
  _mp_rc=1
  for _mp_pid in $(pidof magpie 2>/dev/null); do
    magpie_pid_command "$_mp_pid" "$1" || continue
    echo "$_mp_pid"
    _mp_rc=0
    [ "${2:-}" != first ] || return 0
  done
  return "$_mp_rc"
)

# 主进程 PID：返回第一个真正属于本模块的 serve，不被前面的 CLI 迷惑。
magpie_main_pid() {
  magpie_command_pids serve first
}

# 所有同名进程（仅供 RSS 等统计，不能拿来自动清理）。
magpie_all_pids() {
  pidof magpie 2>/dev/null | tr ' ' '\n' | grep -v '^$'
}

# 只挑本模块的 MCP；普通 update / gateway-key 及其参数不属于孤儿。
magpie_mcp_pids() {
  magpie_command_pids mcp
}

# 服务是否在跑：只看主进程。
# 主进程死了、MCP 子进程残留时，返回真（不在跑），看门狗才会重新拉起。
magpie_running() {
  magpie_main_pid >/dev/null 2>&1
}

# 主进程 + 全部子进程的 RSS 合计（MB）
magpie_rss_mb() {
  _sum=0
  for _p in $(magpie_all_pids); do
    _r=$(awk '/VmRSS/{print $2}' "/proc/$_p/status" 2>/dev/null)
    [ -n "$_r" ] && _sum=$((_sum + _r))
  done
  [ "$_sum" -gt 0 ] && echo "$((_sum / 1024))"
}

# ---------- 本次开机的停止意图 ----------

magpie_valid_boot_id() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' &&
    [ "${#1}" -eq 36 ]
}

magpie_boot_id() (
  _mb_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || exit 1
  magpie_valid_boot_id "$_mb_id" || exit 1
  printf '%s\n' "$_mb_id"
)

# 对无代次的旧标记、读取失败和未知 boot ID 保守：只有两个有效、不同的
# 内核 boot ID 能证明标记过期；不以 Android 尚未校准的墙上时钟猜测。
magpie_stop_intent_current() (
  [ -e "$1" ] || [ -L "$1" ] || exit 1
  [ -f "$1" ] && [ ! -L "$1" ] || exit 0
  IFS= read -r _ms_record < "$1" || exit 0
  case "$_ms_record" in boot=*) _ms_id=${_ms_record#boot=} ;; *) exit 0 ;; esac
  magpie_valid_boot_id "$_ms_id" || exit 0
  _ms_boot=$(magpie_boot_id) || exit 0
  [ "$_ms_id" = "$_ms_boot" ]
)

# ---------- 已核验的 TCP 监听（只读） ----------

# 仅供显示的配置候选 URL，不能据此判断运行态或打开浏览器。
magpie_config_url() (
  _cu_port=$(addr_port "$1") || exit 1
  _cu_host=$(addr_host "$1")
  case "$_cu_host" in
    ''|0.0.0.0) _cu_host=127.0.0.1 ;;
    ::) _cu_host='[::1]' ;;
    *:*)
      case "$_cu_host" in *[!0-9a-fA-F:.]*) exit 1 ;; esac
      _cu_host="[$_cu_host]" ;;
    *[!a-zA-Z0-9.-]*) exit 1 ;;
  esac
  printf 'http://%s:%s\n' "$_cu_host" "$_cu_port"
)

# 不能把某个同名进程、首个还没就绪的 PID 或多个 serve 当作明确归属。
magpie_listener_pid() (
  _ml_pid=$(magpie_command_pids serve 2>/dev/null) || exit 1
  case "$_ml_pid" in ''|0|*[!0-9]*) exit 1 ;; esac
  printf '%s\n' "$_ml_pid"
)

magpie_port_rows() (
  _mr_port=$(addr_port ":$1") || exit 1
  _mr_hex=$(printf '%04X' "$_mr_port") || exit 1
  # 从调用者的网络命名空间同时看两种协议族。读不到任一张表，不把它当成空表。
  awk -v port="$_mr_hex" '
    FNR == 1 { if ($1 == "sl" && $2 == "local_address") headers++; next }
    $4 == "0A" {
      split($2, addr, ":")
      if (toupper(addr[2]) != port) next
      ip = toupper(addr[1]); ip_len = length(ip)
      if ((ip_len != 8 && ip_len != 32) || ip !~ /^[0-9A-F]+$/ || $10 !~ /^[1-9][0-9]*$/) bad = 1
      else print ip, $10
    }
    END { if (headers != 2 || bad) exit 1 }
  ' /proc/self/net/tcp /proc/self/net/tcp6 2>/dev/null
)

# Android arm64 的 /proc TCP 地址按小端 32 位字显示。识别 ::1、127/8 及映射地址。
magpie_tcp_loopback_host() (
  case "$1" in
    00000000000000000000000001000000) printf '[::1]\n'; exit 0 ;;
    0000000000000000FFFF0000??????7F) _mh_v4=${1#0000000000000000FFFF0000} ;;
    ??????7F) _mh_v4=$1 ;;
    *) exit 1 ;;
  esac
  _mh_d=${_mh_v4%??????}; _mh_v4=${_mh_v4#??}
  _mh_c=${_mh_v4%????}; _mh_v4=${_mh_v4#??}
  _mh_b=${_mh_v4%??}
  printf '127.%d.%d.%d\n' "0x$_mh_b" "0x$_mh_c" "0x$_mh_d"
)

# $1 = 已辨认的唯一 serve PID（无则为空），$2 = 端口。
# 输出 local HOST / nonlocal / closed / unknown。端口的每个监听 socket 都要
# 能绑定到该进程的 FD；同端口有其它监听、FD 不可读或采样变化都报告 unknown。
magpie_port_observation() (
  _mo_rows=$(magpie_port_rows "$2") || { echo unknown; exit; }
  [ -n "$_mo_rows" ] || { echo closed; exit; }
  _mo_pid=$1
  case "$_mo_pid" in ''|0|*[!0-9]*) echo unknown; exit ;; esac
  _mo_self_net=$(readlink /proc/self/ns/net 2>/dev/null) || { echo unknown; exit; }
  if [ "$(readlink "/proc/$_mo_pid/ns/net" 2>/dev/null)" != "$_mo_self_net" ] ||
     ! magpie_pid_command "$_mo_pid" serve; then
    echo unknown; exit
  fi

  _mo_sockets=' '
  for _mo_fd in /proc/"$_mo_pid"/fd/*; do
    _mo_link=$(readlink "$_mo_fd" 2>/dev/null) || continue
    case "$_mo_link" in 'socket:['*']') _mo_sockets="$_mo_sockets${_mo_link#socket:} " ;; esac
  done
  _mo_host=''; _mo_nonlocal=0
  while read -r _mo_ip _mo_ino; do
    case "$_mo_sockets" in *" [$_mo_ino] "*) ;; *) echo unknown; exit ;; esac
    if _mo_addr=$(magpie_tcp_loopback_host "$_mo_ip"); then
      # 双栈优先选 IPv4；只有 IPv6 时保留方括号地址。
      case "$_mo_host:$_mo_addr" in :*|'[::1]:127.'*) _mo_host=$_mo_addr ;; esac
    else
      _mo_nonlocal=1
    fi
  done <<EOF
$_mo_rows
EOF
  _mo_after=$(magpie_port_rows "$2") || { echo unknown; exit; }
  if [ "$_mo_rows" != "$_mo_after" ] || ! magpie_pid_command "$_mo_pid" serve ||
     [ "$(readlink "/proc/$_mo_pid/ns/net" 2>/dev/null)" != "$_mo_self_net" ]; then
    echo unknown
  elif [ "$_mo_nonlocal" = 1 ]; then
    echo nonlocal
  elif [ -n "$_mo_host" ]; then
    printf 'local %s\n' "$_mo_host"
  else
    echo unknown
  fi
)

magpie_process_web_binding() (
  case "$1" in ''|0|*[!0-9]*) exit 1 ;; esac
  _mw_args=$(tr '\000\n' '\n\001' 2>/dev/null < "/proc/$1/cmdline") || exit 1
  printf '%s\n' "$_mw_args" | grep -Fxq -- "--web=$2"
)

magpie_listener_report() (
  if [ "$1" = "$2" ]; then
    printf 'api=unknown\nweb=unknown\n'
    exit 0
  fi
  _mlr_pid=$(magpie_listener_pid) || _mlr_pid=''
  printf 'api=%s\nweb=%s\n' "$(magpie_port_observation "$_mlr_pid" "$1")" \
    "$(magpie_port_observation "$_mlr_pid" "$2")"
)

# ---------- DNS ----------
#
# magpie 本体是不链接 libc 的 Go 静态 PIE（cgoAvailable == false），解析域名只能用
# 纯 Go 解析器。它只认 /etc/resolv.conf；读不到就把服务器置为
# 127.0.0.1:53 与 [::1]:53，而 Android 上这两个地址没人监听，
# 于是所有原生 Go 通道都报 `lookup ... on [::1]:53: connection refused`。
# （Go 标准库里没有 DNS_LOCAL_HOSTNAMES，magpie 也不读它，v0.9.0 及以前那份
#  export 从来没有生效过。）所以模块用 Magisk 覆盖提供 /system/etc/resolv.conf，
# 内容由 magpie.service 按 MAGPIE_DNS 重写。

# 点分十进制 IPv4？拒绝前导零：01.2.3.4 在不同解析器里可能按八进制处理
is_ipv4_addr() {
  _ip=$1
  _n=0
  while :; do
    _oct=${_ip%%.*}
    case "$_oct" in
      ''|*[!0-9]*) return 1 ;;
      0*) [ "$_oct" = "0" ] || return 1 ;;
    esac
    [ "${#_oct}" -le 3 ] || return 1
    [ "$_oct" -le 255 ] || return 1
    _n=$((_n + 1))
    [ "$_n" -le 4 ] || return 1
    case "$_ip" in
      *.*) _ip=${_ip#*.} ;;  # 末尾的点也会产生待校验的空段
      *)   break ;;
    esac
  done
  [ "$_n" -eq 4 ]
}

# 1..4 位十六进制
_is_hex4() {
  case "$1" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  [ "${#1}" -le 4 ]
}

# IPv6？只验形状：单独一段 ::、段长 ≤4、段数按 :: 折算，末段允许内嵌 IPv4。
# 不认 zone id（fe80::1%wlan0）——resolv.conf 里写这个没有意义。
is_ipv6_addr() {
  _v=$1
  [ "${#_v}" -le 45 ] || return 1   # 六组 ffff 加点分 IPv4 是最长写法
  case "$_v" in
    :|*:::*|:[!:]*|*[!:]:|*[!0-9a-fA-F:.]*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  case "$_v" in
    *::*) case "${_v#*::}" in *::*) return 1 ;; esac ;;
  esac

  _g=0; _r=$_v
  while [ -n "$_r" ]; do
    _t=${_r%%:*}
    case "$_t" in
      '') ;;   # 空段只能来自上面检查过的 ::
      *.*)
        [ "$_r" = "$_t" ] && is_ipv4_addr "$_t" || return 1
        _g=$((_g + 2)) ;;
      *) _is_hex4 "$_t" || return 1; _g=$((_g + 1)) ;;
    esac
    case "$_r" in *:*) _r=${_r#*:} ;; *) break ;; esac
  done
  # :: 至少替代一个 16 位段；没有 :: 时显式段必须恰好填满 128 位。
  case "$_v" in *::*) [ "$_g" -lt 8 ] ;; *) [ "$_g" -eq 8 ] ;; esac
}

# 合法的 IPv4 / IPv6 字面量？
# 只看格式，不看是否可达、不看是否回环或私网：192.168.1.1 可能是路由器 DNS，
# 127.0.0.1 在用户自建本地 DNS 时也可能真的可用，不能凭地址类型判死。
is_ip_addr() {
  case "$1" in
    ''|*[!0-9a-fA-F:.]*) return 1 ;;
    *:*) is_ipv6_addr "$1" ;;
    *.*) is_ipv4_addr "$1" ;;
    *)   return 1 ;;
  esac
}

# 打出一份 resolv.conf 内容。$1 = 服务器列表（空格分隔）
# 只输出 nameserver 与 options 两种行，不写注释：
# 解析实现一旦遇到整行都没法识别的写法，会把整份文件当无效处理。
# 非法项直接跳过，由调用方用 magpie_bad_dns 点名报出来。
magpie_resolv_body() {
  for _ns in $1; do
    is_ip_addr "$_ns" || continue
    echo "nameserver $_ns"
  done
  echo "options timeout:2 attempts:2"
}

# 列出被跳过的非法上游地址，一行一个（供日志点名，避免用户以为全部生效）
magpie_bad_dns() {
  for _ns in $1; do
    is_ip_addr "$_ns" || echo "$_ns"
  done
}

# ---------- 日志轮转 ----------

# 超过 $2 字节（默认 5MB）就归档成 .1 再清空。$1 = 日志路径
# 返回值只表示「是否发生了轮转」：没超阈值时也返回 0，调用方不必区分。
# 必须在进程打开该日志的 fd **之前**调用：mv 之后旧 inode 仍被持有，
# 晚开会把内容写进已经归档的那份里。
magpie_rotate_log() {
  _f=$1
  _max=${2:-5242880}
  _sz=$(stat -c %s "$_f" 2>/dev/null)
  [ -n "$_sz" ] && [ "$_sz" -gt "$_max" ] 2>/dev/null || return 0
  mv -f "$_f" "$_f.1" 2>/dev/null || return 0
  : > "$_f" 2>/dev/null
  chmod 600 "$_f" 2>/dev/null
  # 只做轮转，不写说明行：调用方的日志措辞不一样
  # （magpie.service 走 log Info 带 [Info] 前缀，service.sh 走裸时间戳）。
  return 0
}

# 服务运行中、进程仍以 O_APPEND 持有日志时用 copytruncate：先复制为 .1，
# 再原地清空；O_APPEND 的写入位置随之回到开头，不留空洞。
# $1 = 日志路径，$2 = 阈值字节。真的发生截断才返回 0。
magpie_truncate_log() {
  _f=$1
  _max=${2:-5242880}
  _sz=$(stat -c %s "$_f" 2>/dev/null)
  [ -n "$_sz" ] && [ "$_sz" -gt "$_max" ] 2>/dev/null || return 1
  cp -f "$_f" "$_f.1" 2>/dev/null || return 1
  chmod 600 "$_f.1" 2>/dev/null
  : > "$_f" 2>/dev/null
  chmod 600 "$_f" 2>/dev/null
  return 0
}

# ---------- 配置 ----------
#
# 配置是 shell 片段，会被 source。BusyBox ash（Magisk/KernelSU 跑 service.sh 用它）
# 遇到语法错误会让整个调用脚本直接退出，mksh 则继续 —— 少一个引号，开机自启和看门狗
# 就一起静默死掉。sh -n 只解析不执行；不通过时调用方改用模块自带的默认配置。
magpie_conf_syntax_ok() {
  [ -f "$1" ] && sh -n "$1" >/dev/null 2>&1
}

# 逐级检查绝对路径；只看末段会漏掉 run 或更上层的链接。不要求目标已存在。
# 先遇到 .. 不能跳过它再作安全判断；其余多余的斜杠或 . 仍逐段回溯。
magpie_path_unlinked() (
  _part=${1:-}
  case "$_part" in /*) ;; *) exit 1 ;; esac
  while [ -n "$_part" ]; do
    case "${_part##*/}" in ..) exit 1 ;; esac
    [ ! -L "$_part" ] || exit 1
    _part=${_part%/*}
  done
)

# 父目录须由调用者另行核对。硬链接也不能改：chmod 会同时作用于目录外的同一 inode。
magpie_single_regular_file() {
  [ ! -L "$1" ] && [ -f "$1" ] && [ "$(stat -c %h "$1" 2>/dev/null)" = 1 ]
}

# 这是自动修整旧权限的授权，不是读取旧配置、手动停服或迁移数据的门槛。
# 历史模块内布局和任意自定义位置都可能仍在使用，不能就地 chmod，也不回退或清理。
magpie_harden_perms() (
  _hp=${1:-}
  [ -n "$_hp" ] && [ "$_hp" = "$(magpie_norm_path "$_hp")" ] &&
    magpie_path_installable "$_hp" && magpie_path_unlinked "$_hp" || exit 0
  cd -P "$_hp" 2>/dev/null && [ "$(pwd -P)" = "$_hp" ] && chmod 700 . 2>/dev/null || exit 0

  for _d in data scripts bin; do
    [ ! -L "$_d" ] || continue
    [ -d "$_d" ] || continue
    _mode=700; [ "$_d" != bin ] || _mode=755
    ( cd -P "./$_d" && [ "$(pwd -P)" = "$_hp/$_d" ] && chmod "$_mode" . ) 2>/dev/null
  done
  # 不通过 run 链接枚举文件；先固定目录并收紧权限，再处理本模块的已知文件。
  [ ! -L run ] && cd -P ./run 2>/dev/null && [ "$(pwd -P)" = "$_hp/run" ] &&
    chmod 700 . 2>/dev/null || exit 0
  for _f in watchdog.log watchdog.log.1 magpie.log magpie.log.1 magpie.pid lan.url \
            .service.flock .stop-intent.flock .tile-install.flock dnsmasq.log dnsmasq.log.1 dnsmasq.pid dnsmasq.keep.pid; do
    magpie_single_regular_file "$_f" && chmod 600 "$_f" 2>/dev/null
  done
  exit 0
)

# ---------- CA 证书包 ----------
#
# magpie 是不链接 libc 的 Go 静态 PIE，只认 /etc/ssl/certs/ca-certificates.crt
# 这类固定路径，而 Android 的证书是 /system/etc/security/cacerts/<hash>.0
# 一证书一文件。所以把系统那几个目录合并成一份，用 SSL_CERT_FILE 指过去。
# 两个来源内容基本相同，按文件名去重。

MAGPIE_CA_DIRS="/system/etc/security/cacerts /apex/com.android.conscrypt/cacerts"

# 系统证书目录指纹：文件数 + 目录 mtime。
# 装/卸根证书模块、系统升级换了 CA 库，指纹都会变，下次启动自动重建。
magpie_ca_fingerprint() {
  _fp=""
  for _d in $MAGPIE_CA_DIRS; do
    if [ -d "$_d" ]; then
      # 用 find 计数：证书文件名虽然都是 hash.0，但 ls 的输出形式
      # 在不同 busybox 版本上不一致（有的会加引号），别在这里赌。
      _n=$(find "$_d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
      _t=$(stat -c %Y "$_d" 2>/dev/null)
      _fp="$_fp ${_d##*/}=${_n}/${_t:-0}"
    else
      _fp="$_fp ${_d##*/}=0/0"
    fi
  done
  echo "$_fp"
}

# 把系统证书合并进 $1。成功时打印合进去的证书张数并返回 0。
# 失败时不动 $1（先写临时文件、校验通过才替换），返回 1 ——
# 重建失败把能用的旧包弄没，比不重建糟得多。
magpie_write_ca_bundle() {
  _out=$1
  [ -n "$_out" ] || return 1
  _dir=$(dirname "$_out")
  mkdir -p "$_dir" 2>/dev/null
  _tmp="$_out.tmp.$$"
  : > "$_tmp" 2>/dev/null || return 1
  _seen=""
  for _d in $MAGPIE_CA_DIRS; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*.0; do
      [ -f "$_f" ] || continue
      case " $_seen " in *" ${_f##*/} "*) continue ;; esac
      _seen="$_seen ${_f##*/}"
      cat "$_f" >> "$_tmp" 2>/dev/null
    done
  done

  _n=$(grep -c 'BEGIN CERTIFICATE' "$_tmp" 2>/dev/null)
  if [ -z "$_n" ] || [ "$_n" -lt 1 ] 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi
  chmod 600 "$_tmp" 2>/dev/null
  if ! mv -f "$_tmp" "$_out" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi
  echo "$_n"
  return 0
}

# ---------- 本体可用性 ----------

# 是不是 ELF（只看头 4 字节）
is_elf_file() {
  [ -n "$1" ] && [ -f "$1" ] || return 1
  [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

# ---------- JSON ----------

# 把字符串变成能安全放进 JSON 双引号里的内容。
# 控制字符（含换行、制表）直接丢掉，反斜杠和双引号转义 —— 这两类字符
# 一旦漏进 status.json，整个文件就不是合法 JSON，面板会整份读不出来。
json_str() {
  printf '%s' "$1" | tr -d '[:cntrl:]' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ---------- 发布 tag ----------

# 发布 tag 是不是 v<数字>[.<数字>...]？
#
# 为什么不用 case 的 glob 一把梭：glob 里除了 . 和 [] 之外都是通配符，
# 所以 `v[0-9]*.[0-9]*` 会放过 `v1junk.2`、`v1.2.3.4.5`、`v.2` 之类。
# 这里按段显式检查：v 开头的每一段必须非空且全是数字，段数 2..4。
is_valid_release_tag() {
  case "$1" in
    v?*) ;;
    *) return 1 ;;
  esac
  # 空段单独拦：循环里 "9." 会被当成最后一段结束，看不出末尾那个点
  case "$1" in
    *.) return 1 ;;
    *..*) return 1 ;;
  esac
  _rest=${1#v}
  _seg=0
  while [ -n "$_rest" ]; do
    _one=${_rest%%.*}
    case "$_one" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#_one}" -le 5 ] || return 1
    _seg=$((_seg + 1))
    case "$_rest" in
      *.*) _rest=${_rest#*.} ;;
      *)   _rest="" ;;
    esac
  done
  [ "$_seg" -ge 2 ] && [ "$_seg" -le 4 ]
}

# ---------- 配置 ----------
# 数据目录默认值。注意：解析配置时 magpie_path 必须还是这个默认值，
# 否则用户改过一次路径后，下一次调用会去新目录找配置、找不到又退回默认值。
MAGPIE_DEFAULT_PATH=/data/adb/magpie

# 打出一份应使用的配置文件路径；都不存在时返回 1。$1 = 模块目录（可选）
# 顺序：MAGPIE_CONF > 数据目录那份（用户改的，模块更新不覆盖）> 模块自带默认
magpie_resolve_conf() {
  _c="${MAGPIE_CONF:-}"
  if [ -n "$_c" ] && [ -f "$_c" ]; then echo "$_c"; return 0; fi
  if [ -f "$MAGPIE_DEFAULT_PATH/scripts/magpie.config" ]; then
    echo "$MAGPIE_DEFAULT_PATH/scripts/magpie.config"; return 0
  fi
  if [ -n "${1:-}" ] && [ -f "$1/scripts/magpie.config" ]; then
    echo "$1/scripts/magpie.config"; return 0
  fi
  return 1
}

# 本体是否「看起来可用」：存在、可执行、是 ELF。
# 这是便宜检查，给看门狗这类高频路径用；要确认真的能跑，
# 用 scripts/install.sh status（它会实际执行 --version）。
magpie_bin_usable() {
  [ -n "$1" ] || return 1
  [ -f "$1" ] && [ -x "$1" ] && is_elf_file "$1"
}
