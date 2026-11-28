#!/system/bin/sh
# 更新模块状态：管理器描述、webroot/status.json、webroot/lastlog.txt
# 用法: sh status.sh              更新全部（含管理器描述 / module.prop）
#       sh status.sh -q           只打印状态文字
#       sh status.sh --webonly    只刷 webroot 下的两个文件，不碰管理器描述
#
# --webonly 供看门狗定期重写快照（默认约 2.5 分钟一次）；不用改模块描述或调用 ksud。

# 直接从管理器或命令行调用时同样不能让未完成的快照/日志临时文件可被旁读。
umask 077
WEB_ONLY=0
_QUIET=0
for _arg in "$@"; do
  case "$_arg" in
    -q) _QUIET=1 ;;
    --webonly) WEB_ONLY=1 ;;
  esac
done

# MAGPIE_CONF 优先：README 与 lib.sh 都这么写，脚本这边以前不认，排障时指定配置无效
CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$CONF" ] || CONF="$(dirname "$0")/magpie.config"

# 模块目录由脚本位置推导，不写死
MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/magpie

# 默认值与 magpie.service 保持一致
magpie_path=/data/adb/magpie
MAGPIE_ADDR="127.0.0.1:3425"
# 环境变量优先于配置文件，方便临时试：MAGPIE_ICON=0 sh status.sh -q
_ENV_ICON="${MAGPIE_ICON-}"
# 语法错误的配置不 source：BusyBox ash 会因此整个退出（见 lib.sh magpie_conf_syntax_ok）
if [ -f "$CONF" ] && ! sh -n "$CONF" >/dev/null 2>&1; then
  echo "! 配置文件有语法错误，已改用默认值：$CONF" >&2
  MAGPIE_CONF_ERROR="配置文件有语法错误（$CONF），已按默认值运行"
else
  [ -f "$CONF" ] && . "$CONF" >/dev/null 2>&1
fi
[ -n "$_ENV_ICON" ] && MAGPIE_ICON="$_ENV_ICON"

# 局域网地址、进程识别、地址解析，和 magpie.service / action.sh / doctor.sh 共用。
# 必须在算端口之前 source：下面要用 addr_port / addr_host / is_loopback_host。
_NETLIB="$(dirname "$0")/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  lan_ip() { return 1; }
  magpie_main_pid() { pidof magpie 2>/dev/null | tr ' ' '\n' | head -1; }
  magpie_rss_mb() { return 1; }
  # 没有 lib.sh 时的退路：宽进（只要能切出数字就用），不在这里重复整套校验。
  addr_host() { case "$1" in \[*\]:*) _h=${1#\[}; echo "${_h%%\]*}" ;; *:*) echo "${1%:*}" ;; *) echo "$1" ;; esac; }
  addr_port() { case "$1" in \[*\]:*) _p=${1##*\]:} ;; *:*) _p=${1##*:} ;; *) return 1 ;; esac; case "$_p" in ''|*[!0-9]*) return 1 ;; esac; echo "$_p"; }
  is_loopback_host() { _h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); case "$_h" in 127.*|localhost|::1|\[::1\]|::ffff:127.*) return 0 ;; esac; return 1; }
  json_str() { printf '%s' "$1" | tr -d '[:cntrl:]' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
fi

# 端口必须是 1..65535 的纯数字。配置写成 127.0.0.1（漏端口）时不能静默退回默认值：
# 那会拼出 http://127.0.0.1:127.0.0.1/v1、写出 "apiPort": 127.0.0.1 这种非法 JSON，
# 面板 r.json() 直接失败，用户还看不见原因。
PORT=$(addr_port "$MAGPIE_ADDR" 2>/dev/null)
[ -n "$PORT" ] || PORT=""
# 面板地址留空是默认用法：跟 magpie.service 一样用「网关主机 + 3430」推出来
WEB_ADDR=${MAGPIE_WEB_ADDR:-"${MAGPIE_ADDR%:*}:3430"}
WEB_PORT=$(addr_port "$WEB_ADDR" 2>/dev/null)
[ -n "$WEB_PORT" ] || WEB_PORT=""

CONFIG_ERROR=""
if [ -n "${MAGPIE_CONF_ERROR:-}" ]; then
  # 按默认值运行仍是可用状态，不清空地址；只把原因带到面板和描述里。
  CONFIG_WARNING=$MAGPIE_CONF_ERROR
fi
if [ -z "$PORT" ]; then
  # 不回显原值：误粘贴的登录链接不应跟着诊断写入状态快照。
  CONFIG_ERROR="MAGPIE_ADDR 的端口不可用，应写成 主机:端口（1-65535，IPv6 用 [::1]:3425）"
elif [ -z "$WEB_PORT" ]; then
  CONFIG_ERROR="MAGPIE_WEB_ADDR 的端口不可用，应写成 主机:端口"
elif [ "$PORT" = "$WEB_PORT" ]; then
  CONFIG_ERROR="网关与面板不能使用同一个端口，请检查 MAGPIE_ADDR 和 MAGPIE_WEB_ADDR"
fi
# 配置有错时仍然输出合法 JSON；错误的端口记为 0，不编一个假地址出来。
[ -n "$PORT" ] || PORT=0
[ -n "$WEB_PORT" ] || WEB_PORT=0

# 记录采样时刻，不把 HTTP 读取时刻或慢操作结束时刻冒充采样时刻。
# 保留旧版 updated 字段；完整时间缺失时输出 0（未知），仍是合法 JSON。
_st=$(date '+%s %H:%M:%S' 2>/dev/null) || _st='0 '
UPDATED_EPOCH=${_st%% *}; UPDATED=${_st#* }
case "$UPDATED_EPOCH" in ''|0*|*[!0-9]*) UPDATED_EPOCH=0 ;; esac

# 只认 serve 主进程：MCP 子进程也叫 magpie，不能拿它们的 PID 当服务状态
PID=$(magpie_main_pid 2>/dev/null)
if [ -n "$PID" ]; then
  RUNNING=1
else
  RUNNING=0
fi

# 地址要实时算：开机时没连 WiFi、之后又连上，或者热点开关切换过，
# 都可能与启动那一刻不同。写死快照会让用户照着旧地址去连。
LAN_IP=$(lan_ip)

# 状态图标：默认用彩色圆点，字体不支持 emoji 时设 MAGPIE_ICON=0 退回纯文本
ICON_ON="${MAGPIE_ICON:-1}"

# 模块列表里那一行的文字。
# 开放局域网且拿得到地址时把地址带上——那才是用户要填进客户端的东西。
desc_line() {
  _v="$1"
  # 配置本身有问题时先说这个：此时显示任何地址都是错的
  if [ -n "$CONFIG_ERROR" ]; then
    if [ "$ICON_ON" = "0" ]; then
      echo "[配置有误] $CONFIG_ERROR"
    else
      echo "🟠 配置有误 | $CONFIG_ERROR"
    fi
    return 0
  fi
  _cw=""
  [ -z "${CONFIG_WARNING:-}" ] || _cw=" | 配置语法错误，已用默认值"
  if [ "$RUNNING" = "1" ]; then
    if is_loopback_host "$(addr_host "$MAGPIE_ADDR")"; then
      _where="配置：仅本机"
    else
      if [ -n "$LAN_IP" ]; then _where="配置候选：$LAN_IP:$PORT"; else _where="无局域网地址"; fi
    fi
    if [ "$ICON_ON" = "0" ]; then
      echo "[运行中] ${_v:+$_v }| $_where$_cw"
    else
      echo "🟢 运行中${_v:+ $_v} | $_where$_cw"
    fi
  else
    if [ "$ICON_ON" = "0" ]; then
      echo "[已停止] 点 [执行] 启动$_cw"
    else
      echo "🔴 已停止 | 点 [执行] 启动$_cw"
    fi
  fi
}

DESC=$(desc_line "")

if [ "$_QUIET" = "1" ]; then
  echo "$DESC"
  exit 0
fi

# 版本取二进制自身（它自带更新，会跟着变）。
# 必须给 HOME，否则 magpie 会往只读的 /.config 写配置。
# 看门狗每 2.5 分钟刷一次面板；每次都跑一遍约 100 MB 的 Go 本体只为拿版本号太浪费。
# 按本体的 inode/大小/mtime 缓存：magpie update 或重装会换掉文件，缓存随之失效。
_ver_bin="$magpie_path/bin/magpie"
_ver_cache="$magpie_path/run/.version"
_ver_key=$(stat -c '%i:%s:%Y' "$_ver_bin" 2>/dev/null)
VERSION=""
if [ -n "$_ver_key" ] && [ -f "$_ver_cache" ] && [ ! -L "$_ver_cache" ]; then
  IFS=' ' read -r _vk _vv < "$_ver_cache" 2>/dev/null
  [ "$_vk" = "$_ver_key" ] && VERSION=$_vv
fi
if [ -z "$VERSION" ]; then
  VERSION=$(HOME="$magpie_path/data" "$_ver_bin" --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$VERSION" ] && [ -n "$_ver_key" ] && [ -d "$magpie_path/run" ] && [ ! -L "$_ver_cache" ]; then
    if ! { printf '%s %s\n' "$_ver_key" "$VERSION" > "$_ver_cache.$$" &&
           mv -f "$_ver_cache.$$" "$_ver_cache"; } 2>/dev/null; then
      rm -f "$_ver_cache.$$" 2>/dev/null
    fi
  fi
fi
[ -n "$VERSION" ] || VERSION="未知"

BIN_BYTES=$(stat -c %s "$magpie_path/bin/magpie" 2>/dev/null)
if [ -n "$BIN_BYTES" ] && [ "$BIN_BYTES" -gt 0 ] 2>/dev/null; then
  BIN_SIZE="$((BIN_BYTES / 1048576)) MB"
else
  BIN_SIZE="未知"
fi

UPTIME="—"
MEM="—"
if [ "$RUNNING" = "1" ]; then
  START_TICKS=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)
  SYS_UP=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
  HZ=$(getconf CLK_TCK 2>/dev/null)
  [ -n "$HZ" ] || HZ=100
  if [ -n "$START_TICKS" ] && [ -n "$SYS_UP" ]; then
    SECS=$((SYS_UP - START_TICKS / HZ))
    [ "$SECS" -lt 0 ] && SECS=0
    D=$((SECS / 86400)); H=$(((SECS % 86400) / 3600)); M=$(((SECS % 3600) / 60))
    if [ "$D" -gt 0 ]; then UPTIME="$D 天 $H 小时"
    elif [ "$H" -gt 0 ]; then UPTIME="$H 小时 $M 分"
    elif [ "$M" -gt 0 ]; then UPTIME="$M 分"
    else UPTIME="$SECS 秒"; fi
  fi
  # 内存算主进程 + MCP 子进程的合计，只报主进程会少一半以上
  _mb=$(magpie_rss_mb 2>/dev/null)
  if [ -z "$_mb" ]; then
    RSS_KB=$(awk '/VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null)
    [ -n "$RSS_KB" ] && _mb=$((RSS_KB / 1024))
  fi
  [ -n "$_mb" ] && MEM="${_mb} MB"
fi

# 监听 0.0.0.0 或具体 IP 视为已开放局域网。
# 回环判定统一走 is_loopback_host：配 ::1 或 [::1]:3425 时也是「仅本机」。
if is_loopback_host "$(addr_host "$MAGPIE_ADDR")"; then LAN_OPEN=0; else LAN_OPEN=1; fi
if is_loopback_host "$(addr_host "$WEB_ADDR")"; then WEB_LAN_OPEN=0; else WEB_LAN_OPEN=1; fi

# API / LAN 地址是配置候选。webUrl 的归属只由控制器核验；入快照前另核对公开格式，
# 即使混用版本或配置向 stdout 打了多余的内容，也不把整段输出或密码链接写入文件。
api_url=''; api_root=''; web_url=''
if [ -z "$CONFIG_ERROR" ]; then
  if api_root=$(magpie_config_url "$MAGPIE_ADDR" 2>/dev/null); then api_url="$api_root/v1"; fi
  if [ "$RUNNING" = 1 ]; then
    _panel=$(MAGPIE_CONF="$CONF" sh "$MODDIR/scripts/magpie.service" panel-url 2>/dev/null) || _panel=''
    case "$_panel" in
      "http://[::1]:$WEB_PORT/") web_url=$_panel ;;
      http://127.*:"$WEB_PORT"/)
        _host=${_panel#http://}
        if is_ipv4_addr "${_host%:"$WEB_PORT"/}" 2>/dev/null; then web_url=$_panel; fi ;;
    esac
    unset _panel _host
  fi
fi
lan_api=''; lan_web=''
if [ -n "$LAN_IP" ] && [ -z "$CONFIG_ERROR" ]; then
  case "$(addr_host "$MAGPIE_ADDR")" in
    ''|0.0.0.0|"$LAN_IP") lan_api="http://$LAN_IP:$PORT/v1" ;;
  esac
  case "$(addr_host "$WEB_ADDR")" in
    ''|0.0.0.0|"$LAN_IP") lan_web="http://$LAN_IP:$WEB_PORT" ;;
  esac
fi

# 原子写：同目录临时文件 → 设权限 → mv 替换。
# 面板反复读取同一文件，直接 > 覆盖的话它可能读到半份 JSON。
# 在权限设置成功后才替换上一份完整文件。
# 同目录 mktemp：并发刷新各写各的，也不复用上次意外退出的临时文件。
write_atomic() {
  _dst=$1
  _tmp=$(mktemp "$_dst.tmp.XXXXXX") || return 1
  if cat > "$_tmp" 2>/dev/null && chmod "${2:-600}" "$_tmp" 2>/dev/null &&
     mv -f "$_tmp" "$_dst" 2>/dev/null; then
    return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  return 1
}

_write_rc=0
cat <<EOF | write_atomic "$MODDIR/webroot/status.json" 600 || _write_rc=1
{
  "running": $([ "$RUNNING" = "1" ] && echo true || echo false),
  "version": "$(json_str "$VERSION")",
  "binSize": "$(json_str "$BIN_SIZE")",
  "pid": "$(json_str "$PID")",
  "uptime": "$(json_str "$UPTIME")",
  "mem": "$(json_str "$MEM")",
  "apiPort": $PORT,
  "apiUrl": "$(json_str "$api_url")",
  "apiUrlRoot": "$(json_str "$api_root")",
  "webPort": $WEB_PORT,
  "webUrl": "$(json_str "$web_url")",
  "lanIp": "$(json_str "$LAN_IP")",
  "lanOpen": $([ "$LAN_OPEN" = "1" ] && echo true || echo false),
  "webLanOpen": $([ "$WEB_LAN_OPEN" = "1" ] && echo true || echo false),
  "lanApiUrl": "$(json_str "$lan_api")",
  "lanWebUrl": "$(json_str "$lan_web")",
  "configError": "$(json_str "$CONFIG_ERROR")",
  "configWarning": "$(json_str "${CONFIG_WARNING:-}")",
  "updatedEpoch": $UPDATED_EPOCH,
  "updated": "$(json_str "$UPDATED")"
}
EOF

# 日志尾供日志标签直接读取，同样原子写
LOG_SRC="$magpie_path/run/magpie.log"
LOG_OUT="$MODDIR/webroot/lastlog.txt"
if [ -f "$LOG_SRC" ]; then
  # 公开面板日志先遮掉常见 URL 凭据、Bearer token 和网关 API key。
  tail -n 30 "$LOG_SRC" 2>/dev/null | sed -E \
    -e 's/([?&]k=)[^&[:space:]]+/\1<redacted>/g' \
    -e 's/((secret|password|token|api[_-]?key)=)[^&[:space:]]+/\1<redacted>/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1<redacted>/g' \
    -e 's/sk-[A-Za-z0-9_-]{8,}/<redacted>/g' \
    | write_atomic "$LOG_OUT" 600 || _write_rc=1
else
  echo "(暂无日志, 服务可能还没启动过)" | write_atomic "$LOG_OUT" 600 || _write_rc=1
fi

# 以下改的是管理器里那一行与 module.prop。--webonly 时跳过：
# 管理器描述只在启停、配置变化时才需要动，定期刷新快照时跳过。
if [ "$WEB_ONLY" != "1" ]; then

# KernelSU / APatch 用 ksud 覆盖描述
for c in /data/adb/ksud /data/adb/ap/bin/ksud; do
  if [ -x "$c" ]; then
    KSU_MODULE=magpie "$c" module config set override.description "$DESC" >/dev/null 2>&1
    break
  fi
done

# Magisk 没有改描述的 CLI，直接改 module.prop 的 description 行。
# 描述里带内核版本：version 是外壳版本，不随 magpie 自身更新变化。
if [ -f "$MODDIR/module.prop" ]; then
  MG_DESC=$(desc_line "v$VERSION")
  _cur=$(sed -n 's/^description=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)
  if [ "$_cur" != "$MG_DESC" ]; then
    if sed "s#^description=.*#description=$MG_DESC#" "$MODDIR/module.prop" \
         > "$MODDIR/.module.prop.new.$$" 2>/dev/null \
       && [ -s "$MODDIR/.module.prop.new.$$" ]; then
      chmod 644 "$MODDIR/.module.prop.new.$$" 2>/dev/null
      mv -f "$MODDIR/.module.prop.new.$$" "$MODDIR/module.prop" 2>/dev/null
      chmod 644 "$MODDIR/module.prop" 2>/dev/null
    else
      rm -f "$MODDIR/.module.prop.new.$$" 2>/dev/null
    fi
  fi
fi

fi  # WEB_ONLY
exit "$_write_rc"
