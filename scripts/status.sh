#!/system/bin/sh
# 更新模块状态：管理器描述、webroot/status.json、webroot/lastlog.txt
# 用法: sh status.sh              更新全部（含管理器描述 / module.prop）
#       sh status.sh -q           只打印状态文字
#       sh status.sh --webonly    只刷 webroot 下的两个文件，不碰管理器描述
#
# --webonly 是给看门狗用的：面板每 5 秒轮询 status.json，要有东西定期重写它
# 数字才会动；但改模块描述、调 ksud 这些一分钟两次没必要，也太吵。

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
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
[ -n "$_ENV_ICON" ] && MAGPIE_ICON="$_ENV_ICON"

# 局域网地址、进程识别、地址解析，和 magpie.service / action.sh / doctor.sh 共用。
# 必须在算端口之前 source：下面要用 addr_port / addr_host / is_loopback_host。
_NETLIB="$(dirname "$0")/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  lan_ip() { return 1; }
  magpie_main_pid() { pidof magpie 2>/dev/null | tr ' ' '\n' | head -1; }
  magpie_all_pids() { pidof magpie 2>/dev/null | tr ' ' '\n' | grep -v '^$'; }
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
WEB_ADDR=${MAGPIE_WEB_ADDR:-}
[ -n "$WEB_ADDR" ] || WEB_ADDR="$(addr_host "$MAGPIE_ADDR"):3430"
WEB_PORT=$(addr_port "$WEB_ADDR" 2>/dev/null)
[ -n "$WEB_PORT" ] || WEB_PORT=""

CONFIG_ERROR=""
if [ -z "$PORT" ]; then
  CONFIG_ERROR="MAGPIE_ADDR=$MAGPIE_ADDR 的端口不可用，应写成 主机:端口（1-65535，IPv6 用 [::1]:3425）"
elif [ -z "$WEB_PORT" ]; then
  CONFIG_ERROR="面板监听地址 $WEB_ADDR 的端口不可用，MAGPIE_WEB_ADDR 应写成 主机:端口"
fi
# 配置有错时仍然输出合法 JSON，但端口类字段留空，不编一个假地址出来
[ -n "$PORT" ] || PORT=0
[ -n "$WEB_PORT" ] || WEB_PORT=0

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
      echo "[配置有误] 监听地址要写成 主机:端口"
    else
      echo "🟠 配置有误 | 监听地址要写成 主机:端口"
    fi
    return 0
  fi
  if [ "$RUNNING" = "1" ]; then
    if is_loopback_host "$(addr_host "$MAGPIE_ADDR")"; then
      _where="仅本机"
    else
      if [ -n "$LAN_IP" ]; then _where="$LAN_IP:$PORT"; else _where="无局域网地址"; fi
    fi
    if [ "$ICON_ON" = "0" ]; then
      echo "[运行中] ${_v:+$_v }| $_where"
    else
      echo "🟢 运行中${_v:+ $_v} | $_where"
    fi
  else
    if [ "$ICON_ON" = "0" ]; then
      echo "[已停止] 点 [执行] 启动"
    else
      echo "🔴 已停止 | 点 [执行] 启动"
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
VERSION=$(HOME="$magpie_path/data" "$magpie_path/bin/magpie" --version 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
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

WEB_URL=$(cat "$magpie_path/run/web.url" 2>/dev/null)
[ -n "$WEB_URL" ] || WEB_URL=""
WEB_KEY=$(cat "$magpie_path/data/web.key" 2>/dev/null)
[ -n "$WEB_KEY" ] || WEB_KEY=""

# 网关 key：回环访问不校验，开放局域网时必需
API_KEY=""
if [ -x "$magpie_path/bin/magpie" ]; then
  API_KEY=$(HOME="$magpie_path/data" MAGPIE_HOME="$magpie_path/data" \
    "$magpie_path/bin/magpie" gateway-key list 2>/dev/null \
    | sed -n 's/^[0-9a-f]\{16,\}[[:space:]]\+[^[:space:]]\+[[:space:]]\+enabled[[:space:]]\+\(sk-[^[:space:]]*\)[[:space:]].*/\1/p' \
    | head -1)
fi
if [ -z "$API_KEY" ]; then
  _cf="$magpie_path/data/.config/magpie/caller-keys.json"
  [ -f "$_cf" ] && API_KEY=$(sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cf" 2>/dev/null | head -1)
fi

# 监听 0.0.0.0 或具体 IP 视为已开放局域网。
# 回环判定统一走 is_loopback_host：配 ::1 或 [::1]:3425 时也是「仅本机」。
if is_loopback_host "$(addr_host "$MAGPIE_ADDR")"; then LAN_OPEN=0; else LAN_OPEN=1; fi

# 端口非法时这些字段留空：不拿 0 拼出一个能点但连不上的地址
api_url=""; api_root=""; web_url=""
[ "$PORT" -gt 0 ] 2>/dev/null && { api_url="http://127.0.0.1:$PORT/v1"; api_root="http://127.0.0.1:$PORT"; }
[ "$WEB_PORT" -gt 0 ] 2>/dev/null && web_url="http://127.0.0.1:$WEB_PORT"
lan_api=""; lan_web=""
if [ -n "$LAN_IP" ]; then
  [ "$PORT" -gt 0 ] 2>/dev/null && lan_api="http://$LAN_IP:$PORT/v1"
  [ "$WEB_PORT" -gt 0 ] 2>/dev/null && lan_web="http://$LAN_IP:$WEB_PORT"
fi

# 原子写：同目录临时文件 → 设权限 → mv 替换。
# 面板每 5 秒来 fetch 一次，直接 > 覆盖的话它可能读到半份 JSON。
# 权限必须在 mv 之前设好，否则替换后到 chmod 之间有一小段 644 的窗口。
# 临时名带 $$：并发刷新时不会互相踩，也不用 $RANDOM（dash 里它是空的）。
write_atomic() {
  _dst=$1
  _tmp="$_dst.tmp.$$"
  if ! cat > "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi
  chmod "${2:-600}" "$_tmp" 2>/dev/null
  if mv -f "$_tmp" "$_dst" 2>/dev/null; then
    return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  return 1
}

cat <<EOF | write_atomic "$MODDIR/webroot/status.json" 600
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
  "apiKey": "$(json_str "$API_KEY")",
  "webPort": $WEB_PORT,
  "webUrl": "$(json_str "$web_url")",
  "webUrlKey": "$(json_str "$WEB_URL")",
  "webKey": "$(json_str "$WEB_KEY")",
  "lanIp": "$(json_str "$LAN_IP")",
  "lanOpen": $([ "$LAN_OPEN" = "1" ] && echo true || echo false),
  "lanApiUrl": "$(json_str "$lan_api")",
  "lanWebUrl": "$(json_str "$lan_web")",
  "configError": "$(json_str "$CONFIG_ERROR")",
  "updated": "$(date +'%H:%M:%S')"
}
EOF

# 日志尾供面板直接 fetch，同样原子写
LOG_SRC="$magpie_path/run/magpie.log"
LOG_OUT="$MODDIR/webroot/lastlog.txt"
if [ -f "$LOG_SRC" ]; then
  tail -n 30 "$LOG_SRC" 2>/dev/null | write_atomic "$LOG_OUT" 600
else
  echo "(暂无日志, 服务可能还没启动过)" | write_atomic "$LOG_OUT" 600
fi

# 以下改的是管理器里那一行与 module.prop。--webonly 时跳过：
# 这些内容只在启停、配置变化时才需要动，没必要每 30 秒重写一次。
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
         > "$MODDIR/.module.prop.new" 2>/dev/null \
       && [ -s "$MODDIR/.module.prop.new" ]; then
      mv -f "$MODDIR/.module.prop.new" "$MODDIR/module.prop" 2>/dev/null
      chmod 644 "$MODDIR/module.prop" 2>/dev/null
    else
      rm -f "$MODDIR/.module.prop.new" 2>/dev/null
    fi
  fi
fi

fi  # WEB_ONLY
