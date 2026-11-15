#!/system/bin/sh
# Magpie for Android - 模块 [执行] 按钮
# 运行中 -> 先打印连接信息，再停止；未运行 -> 启动并打开 WebUI。
# 停止会写 .user_stopped，看门狗不会拉回；下次开机仍会自启。

MODDIR=${0%/*}
SERVICE="$MODDIR/scripts/magpie.service"

CONF=/data/adb/magpie/scripts/magpie.config
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

# 与 magpie.service 保持一致
magpie_path=${magpie_path:-/data/adb/magpie}
MAGPIE_ADDR=${MAGPIE_ADDR:-127.0.0.1:3425}
API_PORT=${MAGPIE_ADDR##*:}
[ -n "$API_PORT" ] || API_PORT=3425
WEB_ADDR=${MAGPIE_WEB_ADDR:-"${MAGPIE_ADDR%:*}:3430"}
WEB_PORT=${WEB_ADDR##*:}
[ -n "$WEB_PORT" ] || WEB_PORT=3430

# 只认 serve 主进程：MCP 子进程也叫 magpie，用 pidof 会误判
is_running() { magpie_running; }

sync_status() {
  [ -f "$MODDIR/scripts/status.sh" ] && sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
}

# 局域网地址实时算，不读 run/lan.url —— 那是启动时的快照，
# WiFi 换过、热点开关过之后就可能指向一个已经不存在的地址。
_NETLIB="$MODDIR/scripts/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  lan_ip() { return 1; }
fi

# 面板地址（带密钥）
panel_url() {
  _k=$(cat "$magpie_path/data/web.key" 2>/dev/null)
  if [ -n "$_k" ]; then
    echo "http://127.0.0.1:$WEB_PORT/?k=$_k"
  else
    echo "http://127.0.0.1:$WEB_PORT/"
  fi
}

# 打印接入信息：本机永远可用；开放局域网时补上行外地址
print_endpoints() {
  echo "  PID      $(magpie_main_pid 2>/dev/null)"
  echo "  网关     http://127.0.0.1:$API_PORT/v1"
  echo "  面板     $(panel_url)"
  case "$MAGPIE_ADDR" in
    127.0.0.1:*|localhost:*) ;;   # 只监听本机，没有行外地址
    *)
      _lan=$(lan_ip)
      if [ -n "$_lan" ]; then
        echo "  局域网   网关 http://$_lan:$API_PORT/v1"
        echo "           面板 http://$_lan:$WEB_PORT  （需访问密码）"
      else
        echo "  局域网   暂无可用地址（未连 WiFi / 热点未开）"
      fi
      ;;
  esac
}

# ---------- 运行中：打印信息后停止 ----------
if is_running; then
  echo "magpie 正在运行:"
  print_endpoints
  echo
  echo "停止 magpie ..."
  sh "$SERVICE" stop

  i=0
  while [ "$i" -lt 25 ]; do
    is_running || break
    sleep 0.2
    i=$((i + 1))
  done

  sync_status

  if is_running; then
    echo "停止失败, 进程仍在运行。日志:"
    tail -n 20 "$magpie_path/run/magpie.log" 2>/dev/null
    exit 1
  fi

  echo "magpie 已停止。再次点击 [执行] 可重新启动。"
  exit 0
fi

# ---------- 未运行：启动 + 打开 WebUI ----------
echo "启动 magpie ..."
sh "$SERVICE" start

i=0
while [ "$i" -lt 20 ]; do
  is_running && break
  sleep 0.5
  i=$((i + 1))
done

if ! is_running; then
  echo "启动失败, 日志:"
  tail -n 20 "$magpie_path/run/magpie.log" 2>/dev/null
  sync_status
  exit 1
fi

echo "magpie 已启动:"
print_endpoints

URL=$(panel_url)
echo
echo "打开面板: http://127.0.0.1:$WEB_PORT"
# 指定 user 0，否则 root shell 下 am 可能因用户不确定而失败
am start -a android.intent.action.VIEW -d "$URL" --user 0 2>/dev/null \
  || am start -a android.intent.action.VIEW -d "$URL" 2>/dev/null \
  || echo "请手动在浏览器打开上面的地址"

echo
echo "再次点击 [执行] 可停止。"
sync_status
