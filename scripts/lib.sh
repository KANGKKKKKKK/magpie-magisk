#!/system/bin/sh
# 公共工具：局域网地址探测 + magpie 进程识别。
# 被 magpie.service / status.sh / action.sh / doctor.sh / service.sh 共用。
# 只定义函数，不做任何动作。

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
lan_ip() {
  for _if in wlan0 wlan1 ap0 usb0 rndis0 eth0; do
    for _a in $(ip -4 addr show "$_if" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p'); do
      is_usable_lan_ip "$_a" && { echo "$_a"; return 0; }
    done
  done
  for _if in $(ip -4 -o addr show 2>/dev/null | sed -n 's/^[0-9]*: \([^ ]*\) .*/\1/p'); do
    case "$_if" in lo|ccmni*|rmnet*|clat*) continue ;; esac
    for _a in $(ip -4 addr show "$_if" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p'); do
      is_usable_lan_ip "$_a" && { echo "$_a"; return 0; }
    done
  done
  return 1
}

# ---------- 进程 ----------
#
# magpie 主进程是 `magpie serve --web=...`，但它还会拉起同名的子进程：
#   magpie mcp vision / mcp search / mcp image
# `pidof magpie` 一次返回全部，head -1 拿到的可能是子进程而不是网关本身。
# 所以凡是「服务是否在跑」「该杀哪个」的判断，都必须先认出主进程。

# 主进程 PID（命令行里带 serve 的那个）
magpie_main_pid() {
  for _p in $(pidof magpie 2>/dev/null); do
    [ -r "/proc/$_p/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q -- ' serve'; then
      echo "$_p"
      return 0
    fi
  done
  return 1
}

# 所有 magpie 进程（含 MCP 子进程），一行一个
magpie_all_pids() {
  pidof magpie 2>/dev/null | tr ' ' '\n' | grep -v '^$'
}

# 只挑 MCP 子进程（命令行里带 ` mcp `）。
# 自动清理只能用它：用户手上可能正在跑 `magpie update` 之类的命令，
# 那不是孤儿，不能被顺手杀掉。
magpie_mcp_pids() {
  for _p in $(magpie_all_pids 2>/dev/null); do
    [ -r "/proc/$_p/cmdline" ] || continue
    _cl=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
    case "$_cl" in
      *" mcp "*) echo "$_p" ;;
    esac
  done
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

# ---------- DNS ----------
#
# magpie 本体是静态编译的 Go 程序（cgoAvailable == false），解析域名只能用
# 纯 Go 解析器。它只认 /etc/resolv.conf；读不到就把服务器置为
# 127.0.0.1:53 与 [::1]:53，而 Android 上这两个地址没人监听，
# 于是所有原生 Go 通道都报 `lookup ... on [::1]:53: connection refused`。
# （Go 标准库里没有 DNS_LOCAL_HOSTNAMES，magpie 也不读它，v0.9.0 及以前那份
#  export 从来没有生效过。）所以模块用 Magisk 覆盖提供 /system/etc/resolv.conf，
# 内容由 magpie.service 按 MAGPIE_DNS 重写。

# 打出一份 resolv.conf 内容。$1 = 服务器列表（空格分隔）
# 只输出 nameserver 与 options 两种行，不写注释：
# 解析实现一旦遇到整行都没法识别的写法，会把整份文件当无效处理。
magpie_resolv_body() {
  for _ns in $1; do
    case "$_ns" in
      *[!0-9a-fA-F:.]*|'') continue ;;
    esac
    echo "nameserver $_ns"
  done
  echo "options timeout:2 attempts:2"
}

# ---------- 本体可用性 ----------

# 是不是 ELF（只看头 4 字节）
is_elf_file() {
  [ -n "$1" ] && [ -f "$1" ] || return 1
  [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
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
