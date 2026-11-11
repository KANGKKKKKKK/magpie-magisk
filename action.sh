#!/system/bin/sh
# Magpie for Android - 模块 [执行] 按钮
# 运行中 -> 停止；未运行 -> 启动并打开 WebUI。
# 停止会写 .user_stopped，看门狗不会拉回；下次开机仍会自启。

MODDIR=${0%/*}
SERVICE="$MODDIR/scripts/magpie.service"

CONF=/data/adb/magpie/scripts/magpie.config
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

# 与 magpie.service 保持一致
magpie_path=${magpie_path:-/data/adb/magpie}
MAGPIE_ADDR=${MAGPIE_ADDR:-127.0.0.1:3425}
WEB_ADDR=${MAGPIE_WEB_ADDR:-"${MAGPIE_ADDR%:*}:3430"}
WEB_PORT=${WEB_ADDR##*:}
[ -n "$WEB_PORT" ] || WEB_PORT=3430

is_running() { pidof magpie >/dev/null 2>&1; }

sync_status() {
  [ -f "$MODDIR/scripts/status.sh" ] && sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
}

# ---------- 运行中：停止 ----------
if is_running; then
  PID=$(pidof magpie 2>/dev/null | tr ' ' '\n' | head -1)
  echo "停止 magpie (PID $PID) ..."
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

WEB_KEY=$(cat "$magpie_path/data/web.key" 2>/dev/null)
URL="http://127.0.0.1:$WEB_PORT/"
[ -n "$WEB_KEY" ] && URL="http://127.0.0.1:$WEB_PORT/?k=$WEB_KEY"

echo "打开 WebUI: http://127.0.0.1:$WEB_PORT"
# 指定 user 0，否则 root shell 下 am 可能因用户不确定而失败
am start -a android.intent.action.VIEW -d "$URL" --user 0 2>/dev/null \
  || am start -a android.intent.action.VIEW -d "$URL" 2>/dev/null \
  || echo "请手动在浏览器打开上面的地址"

echo "magpie 运行中。再次点击 [执行] 可停止。"
sync_status
