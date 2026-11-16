#!/system/bin/sh
# Magpie for Android - 开机自启 + 看门狗

MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0

LOG_MAX_BYTES=5242880
# 配置查找顺序与 magpie.service / status.sh / action.sh / doctor.sh 保持一致
CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
MP=${magpie_path:-/data/adb/magpie}

# run 目录必须先建出来：下面所有 `>>"$WATCH_LOG"` 都指向它。
# 目录不存在时重定向直接失败、命令根本不会被执行 —— 首次开机（本体刚装好、
# 还没手动启动过）就会永远起不来。建不出来时把日志丢弃，但服务照常尝试启动。
mkdir -p "$MP/run" 2>/dev/null
if [ -d "$MP/run" ]; then
  WATCH_LOG="$MP/run/watchdog.log"
else
  WATCH_LOG=/dev/null
fi

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

  # 局域网地址与进程识别（与 magpie.service 共用实现）
  _NETLIB="$MODDIR/scripts/lib.sh"
  if [ -f "$_NETLIB" ]; then
    . "$_NETLIB"
  else
    lan_ip() { return 1; }
    magpie_running() { pidof magpie >/dev/null 2>&1; }
    magpie_bin_usable() { [ -x "$1" ]; }
  fi

  _last_lan=""
  _wait=20          # 下一轮睡多久；失败时退避，成功即复位
  _miss_logged=0    # 本体缺失只记一次，不刷日志
  _fail=0           # 连续拉起失败次数

  # 万一 run 目录被清理工具删掉，先补回来，免得下面重定向失败
  mkdir -p "$MP/run" 2>/dev/null

  while :; do
    sleep "$_wait"
    _wait=20

    # run 目录不在时重定向会失败、命令不会执行，每轮顺手补一次
    [ -d "$MP/run" ] || mkdir -p "$MP/run" 2>/dev/null

    # 模块被禁用、正在卸载或已被删除，守护都该退出
    [ -f "$MODDIR/disable" ] && { wlog "模块已禁用, 守护退出"; exit 0; }
    [ -f "$MODDIR/.uninstalling" ] && { wlog "模块卸载中, 守护退出"; exit 0; }
    [ -d "$MODDIR" ] || exit 0

    # 本体不在或不可执行：跳过这一轮，别每 20 秒撞一次墙刷日志
    if ! magpie_bin_usable "$MP/bin/magpie"; then
      if [ "$_miss_logged" = "0" ]; then
        wlog "本体未安装或不可用（$MP/bin/magpie），暂停重启尝试"
        wlog "  装好用 sh $MODDIR/scripts/install.sh install --yes，或在管理器点 [执行]"
        _miss_logged=1
      fi
      _wait=300
      rotate_log "$WATCH_LOG"
      continue
    fi
    if [ "$_miss_logged" = "1" ]; then
      wlog "本体已就位，恢复巡检"
      _miss_logged=0
      _fail=0
    fi

    # 存在 .user_stopped 表示用户主动停止，不要拉回
    if [ ! -f "$MP/run/.user_stopped" ] && ! magpie_running; then
      wlog "magpie 未运行, 重新拉起"
      if sh "$MODDIR/scripts/magpie.service" start >>"$WATCH_LOG" 2>&1; then
        _fail=0
        sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
      else
        # 拉起失败时指数退避，最长 10 分钟一次，避免一直刷日志
        _fail=$((_fail + 1))
        _wait=20
        _i=1
        while [ "$_i" -lt "$_fail" ] && [ "$_wait" -lt 600 ]; do
          _wait=$((_wait * 2))
          _i=$((_i + 1))
        done
        [ "$_wait" -gt 600 ] && _wait=600
        wlog "拉起失败（连续 $_fail 次），$_wait 秒后再试"
      fi
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
          wlog "局域网地址 ${_old:-无} -> ${_cur_lan:-无}"
          sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
        fi
      fi
    fi

    rotate_log "$WATCH_LOG"
  done
) &
