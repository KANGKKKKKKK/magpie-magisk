#!/system/bin/sh
# 公共工具：局域网地址探测 + magpie 进程识别。
# 被 magpie.service / status.sh / action.sh / doctor.sh / service.sh 共用。
# 只定义函数，不做任何动作。

# ---------- 监听地址 ----------
#
# 配置里的 MAGPIE_ADDR / MAGPIE_WEB_ADDR 形如 "host:port"。
# IPv6 必须写方括号（[::1]:3425），否则最后一个冒号分不清是端口还是地址的一部分。

# 取主机部分，不校验；IPv6 会去掉方括号（返回 ::1 而不是 [::1]）
addr_host() {
  case "$1" in
    \[*\]:*) _h=${1#\[}; echo "${_h%%\]*}" ;;
    \[*\])   _h=${1#\[}; echo "${_h%\]}" ;;
    *:*)     echo "${1%:*}" ;;
    *)       echo "$1" ;;
  esac
}

# 取端口；不是 1..65535 的纯数字时返回 1，不打印任何东西。
# 调用方必须按失败处理：静默退回默认端口会把配置错误藏起来，
# 拼出 "http://127.0.0.1:0.0.0.0/v1" 这种链接、写出非法 JSON。
addr_port() {
  case "$1" in
    \[*\]:*) _p=${1##*\]:} ;;
    \[*\])   return 1 ;;
    *:*)     _p=${1##*:} ;;
    *)       return 1 ;;
  esac
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  case "$_p" in 0*) return 1 ;; esac          # 端口 0、前导零都当非法
  [ "${#_p}" -le 5 ] || return 1
  [ "$_p" -le 65535 ] || return 1
  echo "$_p"
}

# 回环地址？认 127/8、localhost、::1（含方括号与完整写法）。
# 空主机（":3425"）表示监听全部网卡，不算回环。
is_loopback_host() {
  # IPv6 的十六进制位大小写不敏感：::FFFF:127.0.0.1 与 ::ffff:127.0.0.1 是同一个地址。
  # 以前只匹配小写，大写写法会被判成「已开放局域网」—— 安全边界说反了。
  _h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$_h" in
    127.*|localhost|::1|\[::1\]|0:0:0:0:0:0:0:1) return 0 ;;
    # IPv4-mapped：::ffff:127.x 仍然是回环
    ::ffff:127.*|\[::ffff:127.*\]) return 0 ;;
  esac
  return 1
}

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
  # 折叠重复斜杠（不处理 ".." —— 调用方另有逐级上溯检查）
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

# 这个路径是不是「绝不能删」的那一类。返回 0 表示可以删。
# 传进来的路径会先归一化，所以 "/data/" 与 "/data" 等价。
magpie_path_cleanable() {
  _c=$(magpie_norm_path "$1" 2>/dev/null) || return 1

  # 精确拦：这些目录本身绝不能被整个删掉
  case "$_c" in
    ''|/|/data|/data/adb|/data/adb/modules|/data/local|/data/app|/data/data|/data/system)
      return 1 ;;
    /sdcard|/storage|/storage/emulated|/storage/emulated/0)
      return 1 ;;
    /mnt|/system|/vendor|/product|/apex)
      return 1 ;;
  esac

  # 前缀拦：这些目录下面的任何东西也不删。
  # /data/adb/modules/<某个模块> 不在此列 —— 那正是要删的目标。
  case "$_c" in
    /data/adb/modules/*/*) return 1 ;;
    /sdcard/*|/storage/*|/mnt/*) return 1 ;;
    /system/*|/vendor/*|/product/*|/apex/*) return 1 ;;
    /data/local/*|/data/app/*|/data/data/*|/data/system/*) return 1 ;;
  esac

  return 0
}

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
  while [ -n "$_ip" ]; do
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
      *.*) _ip=${_ip#*.} ;;
      *)   _ip="" ;;
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
  case "$_v" in
    ''|*%*|*:::*|*[!0-9a-fA-F:.]*) return 1 ;;
  esac
  case "$_v" in *:*) ;; *) return 1 ;; esac
  case "$_v" in
    *::*) case "${_v#*::}" in *::*) return 1 ;; esac ;;
  esac

  _c=0; _r=$_v
  while [ -n "$_r" ]; do
    case "$_r" in :*) _c=$((_c + 1)) ;; esac
    _r=${_r#?}
  done

  # "::" 至少吃掉一段，所以显式段数必须 ≤7；没有 "::" 时必须正好 8 段
  _g=$((_c + 1))
  case "$_v" in
    *::*) _g=$((_g - 2)); [ "$_g" -le 7 ] || return 1 ;;
    *)    [ "$_g" -eq 8 ] || return 1 ;;
  esac
  [ "$_g" -ge 0 ] || return 1

  _r=$_v
  while :; do
    case "$_r" in
      *:*) _t=${_r%%:*}; _r=${_r#*:}; _more=1 ;;
      *)   _t=$_r; _more=0 ;;
    esac
    if [ -n "$_t" ]; then
      if [ "$_more" = "0" ]; then
        case "$_t" in
          *.*) is_ipv4_addr "$_t" || return 1 ;;
          *)   _is_hex4 "$_t" || return 1 ;;
        esac
      else
        _is_hex4 "$_t" || return 1
      fi
    fi
    [ "$_more" = "1" ] || break
  done
  return 0
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
