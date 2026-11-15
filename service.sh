#!/system/bin/sh
# Magpie for Android - 开机自启 + 看门狗

MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0

LOG_MAX_BYTES=5242880
CONF=/data/adb/magpie/scripts/magpie.config
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
MP=${magpie_path:-/data/adb/magpie}
WATCH_LOG="$MP/run/watchdog.log"

# 超过 5MB 归档为 .1，必须在进程打开日志 fd 之前调用
rotate_log() {
  _f="$1"
  _sz=$(stat -c %s "$_f" 2>/dev/null)
  [ -n "$_sz" ] && [ "$_sz" -gt "$LOG_MAX_BYTES" ] 2>/dev/null || return 0
  mv -f "$_f" "$_f.1" 2>/dev/null || return 0
  : > "$_f" 2>/dev/null
  chmod 600 "$_f" 2>/dev/null
  echo "$(date +'%Y-%m-%d %H:%M:%S') 日志超 5MB, 已归档为 ${_f##*/}.1" >> "$_f" 2>/dev/null
}

# 开机后拉起服务，不阻塞启动流程
(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 3; done
  rotate_log "$MP/run/magpie.log"
  # 启动日志留在看门狗日志里，否则开机时 stdout 直接丢弃
  sh "$MODDIR/scripts/magpie.service" start >>"$WATCH_LOG" 2>&1
  sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
) &

# 看门狗：进程被杀或系统回收后重新拉起
(
  wlog() { echo "$(date +'%Y-%m-%d %H:%M:%S') $1" >> "$WATCH_LOG" 2>/dev/null; }

  # 局域网地址探测（与 magpie.service 共用实现）
  _NETLIB="$MODDIR/scripts/lib.sh"
  if [ -f "$_NETLIB" ]; then . "$_NETLIB"; else lan_ip() { return 1; }; fi

  # 上次刷新时的地址，用来判断有没有变
  _last_lan=""

  while :; do
    sleep 20

    # 模块被禁用、正在卸载或已被删除，守护都该退出
    [ -f "$MODDIR/disable" ] && { wlog "模块已禁用, 守护退出"; exit 0; }
    [ -f "$MODDIR/.uninstalling" ] && { wlog "模块卸载中, 守护退出"; exit 0; }
    [ -d "$MODDIR" ] || exit 0

    # 存在 .user_stopped 表示用户主动停止，不要拉回
    if [ ! -f "$MP/run/.user_stopped" ] && ! magpie_running; then
      wlog "magpie 未运行, 重新拉起"
      sh "$MODDIR/scripts/magpie.service" start >>"$WATCH_LOG" 2>&1
      sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
    fi

    # 服务在跑时盯住局域网地址：WiFi 重连、热点开关、切飞行模式
    # 都会让地址变化，而 run/lan.url 和 module.prop 的描述都是那一刻写死的。
    # 变了就刷新，免得用户照着旧地址连不上。
    if magpie_running; then
      _cur_lan=$(lan_ip)
      if [ "$_cur_lan" != "$_last_lan" ]; then
        _last_lan="$_cur_lan"
        _old=$(cat "$MP/run/lan.url" 2>/dev/null)
        _old=$(echo "$_old" | sed -n 's#^http://\([^:]*\):.*#\1#p')
        if [ "$_cur_lan" != "$_old" ]; then
          echo "$(date +'%Y-%m-%d %H:%M:%S') 局域网地址 ${_old:-无} -> ${_cur_lan:-无}" >>"$WATCH_LOG" 2>/dev/null
          sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
        fi
      fi
    fi

    rotate_log "$WATCH_LOG"
  done
) &
