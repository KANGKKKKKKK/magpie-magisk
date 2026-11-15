#!/system/bin/sh
# 更新模块状态：管理器描述、webroot/status.json、webroot/lastlog.txt
# 用法: sh status.sh       更新全部
#       sh status.sh -q    只打印状态文字

CONF=/data/adb/magpie/scripts/magpie.config
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

PORT=${MAGPIE_ADDR##*:}
[ -n "$PORT" ] || PORT=3425
WEB_PORT=${MAGPIE_WEB_ADDR##*:}
[ -n "$WEB_PORT" ] || WEB_PORT=3430

# 局域网地址与进程识别，和 magpie.service / action.sh / doctor.sh 共用
_NETLIB="$(dirname "$0")/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  lan_ip() { return 1; }
  magpie_main_pid() { pidof magpie 2>/dev/null | tr ' ' '\n' | head -1; }
  magpie_all_pids() { pidof magpie 2>/dev/null | tr ' ' '\n' | grep -v '^$'; }
  magpie_rss_mb() { return 1; }
fi

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
  if [ "$RUNNING" = "1" ]; then
    case "$MAGPIE_ADDR" in
      127.0.0.1:*|localhost:*)
        _where="仅本机" ;;
      *)
        if [ -n "$LAN_IP" ]; then _where="$LAN_IP:$PORT"; else _where="无局域网地址"; fi ;;
    esac
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

if [ "$1" = "-q" ]; then
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

# 监听 0.0.0.0 或具体 IP 视为已开放局域网
case "$MAGPIE_ADDR" in
  127.0.0.1:*|localhost:*) LAN_OPEN=0 ;;
  *)                       LAN_OPEN=1 ;;
esac

cat > "$MODDIR/webroot/status.json" <<EOF
{
  "running": $([ "$RUNNING" = "1" ] && echo true || echo false),
  "version": "$VERSION",
  "binSize": "$BIN_SIZE",
  "pid": "$PID",
  "uptime": "$UPTIME",
  "mem": "$MEM",
  "apiPort": $PORT,
  "apiUrl": "http://127.0.0.1:$PORT/v1",
  "apiUrlRoot": "http://127.0.0.1:$PORT",
  "apiKey": "$API_KEY",
  "webPort": $WEB_PORT,
  "webUrl": "http://127.0.0.1:$WEB_PORT",
  "webUrlKey": "$WEB_URL",
  "webKey": "$WEB_KEY",
  "lanIp": "$LAN_IP",
  "lanOpen": $([ "$LAN_OPEN" = "1" ] && echo true || echo false),
  "lanApiUrl": "$([ -n "$LAN_IP" ] && echo "http://$LAN_IP:$PORT/v1")",
  "lanWebUrl": "$([ -n "$LAN_IP" ] && echo "http://$LAN_IP:$WEB_PORT")",
  "updated": "$(date +'%H:%M:%S')"
}
EOF
chmod 600 "$MODDIR/webroot/status.json" 2>/dev/null

# 日志尾供面板直接 fetch
LOG_SRC="$magpie_path/run/magpie.log"
LOG_OUT="$MODDIR/webroot/lastlog.txt"
if [ -f "$LOG_SRC" ]; then
  tail -n 30 "$LOG_SRC" > "$LOG_OUT" 2>/dev/null
else
  echo "(暂无日志, 服务可能还没启动过)" > "$LOG_OUT"
fi
chmod 600 "$LOG_OUT" 2>/dev/null

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
