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
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

PORT=${MAGPIE_ADDR##*:}
[ -n "$PORT" ] || PORT=3425
WEB_PORT=${MAGPIE_WEB_ADDR##*:}
[ -n "$WEB_PORT" ] || WEB_PORT=3430

PID=$(pidof magpie 2>/dev/null)
if [ -n "$PID" ]; then
  RUNNING=1
else
  RUNNING=0
fi

if [ "$RUNNING" = "1" ]; then
  DESC="magpie 运行中 | WebUI: http://127.0.0.1:$WEB_PORT"
else
  DESC="magpie 已停止 | 点 [执行] 启动服务"
fi

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
  RSS_KB=$(awk '/VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null)
  [ -n "$RSS_KB" ] && MEM="$((RSS_KB / 1024)) MB"
fi

# 局域网 IP：排除回环、链路本地和 mihomo 的 fake-ip 段，
# 规则与 magpie.service 的 lan_ip() 一致。
is_usable_lan_ip() {
  case "$1" in
    ''|0.0.0.0|127.*|169.254.*|198.18.*|198.19.*) return 1 ;;
  esac
  return 0
}

lan_ip() {
  for _if in wlan0 wlan1 ccmni0 ccmni1; do
    for _a in $(ip -4 addr show "$_if" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p'); do
      is_usable_lan_ip "$_a" && { echo "$_a"; return 0; }
    done
  done
  for _a in $(ip -4 -o addr show 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p'); do
    is_usable_lan_ip "$_a" && { echo "$_a"; return 0; }
  done
  return 1
}

LAN_IP=$(lan_ip)

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
  if [ "$RUNNING" = "1" ]; then
    MG_DESC="magpie 运行中 (v$VERSION) | 点 [执行] 停止"
  else
    MG_DESC="magpie 已停止 | 点 [执行] 启动"
  fi
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
