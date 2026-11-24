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

# 公共实现提前 source：下面 rotate_log 和看门狗的进程识别都要用。
# 放在顶层而不是子 shell 里 —— 子 shell 里的函数定义不会回到父 shell。
_NETLIB="$MODDIR/scripts/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  lan_ip() { return 1; }
  magpie_running() { pidof magpie >/dev/null 2>&1; }
  magpie_bin_usable() { [ -x "$1" ]; }
fi

# 超过 5MB 归档为 .1，必须在进程打开日志 fd 之前调用。
# 轮转本身在 lib.sh（magpie.service 共用同一份），这里只补一行说明。
rotate_log() {
  _f="$1"
  if command -v magpie_rotate_log >/dev/null 2>&1; then
    _sz=$(stat -c %s "$_f" 2>/dev/null)
    [ -n "$_sz" ] && [ "$_sz" -gt "$LOG_MAX_BYTES" ] 2>/dev/null || return 0
    magpie_rotate_log "$_f" "$LOG_MAX_BYTES"
    echo "$(date +'%Y-%m-%d %H:%M:%S') 日志超 5MB, 已归档为 ${_f##*/}.1" >> "$_f" 2>/dev/null
    return 0
  fi
  return 0
}

# 等开机完成。下面两条启动路径（首次拉起 + 看门狗）都要先过这里：
# 以前只有首次拉起那个子 shell 等 sys.boot_completed，看门狗没等，
# 于是它可能在开机过程中就开跑、抢先 start 一次，和首次启动撞在一起
# （后到的那个因为端口被占而失败，白记一条「拉起失败」）。
# 上限可调、且等不到也继续：getprop 不可用、或某些机器 boot_completed 一直为空时，
# 让服务永远起不来比早启动几秒糟得多。测试里把 MAGPIE_BOOT_WAIT_SECS 调小；
# 设 0 表示完全不等。
BOOT_WAIT_MAX=${MAGPIE_BOOT_WAIT_SECS:-600}
wait_boot_completed() {
  _deadline=$(($(date +%s) + BOOT_WAIT_MAX))
  until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do
    [ "$(date +%s)" -lt "$_deadline" ] || return 1
    sleep 3
  done
  return 0
}

# 开机后拉起服务，不阻塞启动流程
(
  wait_boot_completed
  # 等待期间模块可能被禁用（开机那几分钟足够点一下）
  [ -f "$MODDIR/disable" ] && exit 0
  rotate_log "$MP/run/magpie.log"
  # 启动日志留在看门狗日志里，否则开机时 stdout 直接丢弃
  sh "$MODDIR/scripts/magpie.service" start >>"$WATCH_LOG" 2>&1
  sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
) &

# 巡检间隔。改这里就够，下面的退避也从它起算。
# 30 秒是权衡：更短能更快把挂掉的服务拉回来，但每轮都要读 /proc、比对局域网地址；
# 模块自己也常在待机，别为了秒级响应去叫醒 CPU。
WATCH_INTERVAL=${MAGPIE_WATCH_INTERVAL:-30}

# 看门狗：进程被杀或系统回收后重新拉起
(
  wlog() { echo "$(date +'%Y-%m-%d %H:%M:%S') $1" >> "$WATCH_LOG" 2>/dev/null; }

  _last_lan=""
  _wait=$WATCH_INTERVAL   # 下一轮睡多久；失败时退避，成功即复位
  _miss_logged=0    # 本体缺失只记一次，不刷日志
  _fail=0           # 连续拉起失败次数
  _tick=0           # 面板状态刷新计数

  # 万一 run 目录被清理工具删掉，先补回来，免得下面重定向失败
  mkdir -p "$MP/run" 2>/dev/null

  # 与上面的首次拉起用同一段等待：不让看门狗在开机过程中抢先 start
  wait_boot_completed

  while :; do
    sleep "$_wait"
    #<<< WATCHDOG-BODY（这行之后是循环体；tests/test-watchdog.sh 按标记抽取。
    #    sleep 留在标记外面：测试里 _wait 会按退避序列涨到几百秒，
    #    真睡下去会把测试拖成全量几分钟。）
    _wait=$WATCH_INTERVAL

    # run 目录不在时重定向会失败、命令不会执行，每轮顺手补一次
    [ -d "$MP/run" ] || mkdir -p "$MP/run" 2>/dev/null

    # 模块被禁用、正在卸载或已被删除，守护都该退出
    [ -f "$MODDIR/disable" ] && { wlog "模块已禁用, 守护退出"; exit 0; }
    [ -f "$MODDIR/.uninstalling" ] && { wlog "模块卸载中, 守护退出"; exit 0; }
    [ -d "$MODDIR" ] || exit 0

    # 本体不在或不可执行：跳过这一轮，别每轮都撞墙刷日志
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
        _wait=$WATCH_INTERVAL
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

    # 面板每 5 秒轮询 status.json，得有人定期重写它数字才会动。
    # 每 5 轮（默认约 2.5 分钟）刷一次：再密就是拿 magpie 子进程
    # （--version + gateway-key list 约 0.3 秒）去换用户看不出差别的数字。
    # 用 --webonly：不碰模块描述，也就不去调 ksud / 重写 module.prop。
    _tick=$((_tick + 1))
    if [ "$_tick" -ge 5 ]; then
      _tick=0
      sh "$MODDIR/scripts/status.sh" --webonly >/dev/null 2>&1
    fi

    rotate_log "$WATCH_LOG"
    #>>> WATCHDOG-BODY
  done
) &
