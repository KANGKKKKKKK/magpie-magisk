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

# ---------- 本体可用性 ----------

# 是不是 ELF（只看头 4 字节）
is_elf_file() {
  [ -n "$1" ] && [ -f "$1" ] || return 1
  [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

# 本体是否「看起来可用」：存在、可执行、是 ELF。
# 这是便宜检查，给看门狗这类高频路径用；要确认真的能跑，
# 用 scripts/install.sh status（它会实际执行 --version）。
magpie_bin_usable() {
  [ -n "$1" ] || return 1
  [ -f "$1" ] && [ -x "$1" ] && is_elf_file "$1"
}
