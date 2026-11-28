#!/system/bin/sh
# Magpie for Android - 开机自启 + 看门狗

MODDIR=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P) || exit 1
# 持有此安装目录的引用；卸载后同路径重装，旧任务不能接管新的模块。
cd -P "$MODDIR" || exit 1
BOOT_DIR_ID=$(stat -c '%d:%i' .) || exit 1
boot_module_active() {
  [ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/.uninstalling" ] &&
    [ "$(stat -c '%d:%i' "$MODDIR" 2>/dev/null)" = "$BOOT_DIR_ID" ]
}
# Magisk 拉起 service.sh 时 umask 可能是 0000：不收紧的话日志、锁、run/ 都会是 666/777。
umask 077
boot_module_active || exit 0

LOG_MAX_BYTES=5242880
# 配置查找顺序与 magpie.service / status.sh / action.sh / doctor.sh 保持一致
CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
# 语法错误的配置不 source：BusyBox ash 会因此整个退出（见 lib.sh magpie_conf_syntax_ok）
if [ -f "$CONF" ] && ! sh -n "$CONF" >/dev/null 2>&1; then
  echo "! 配置文件有语法错误，已改用默认值：$CONF" >&2
else
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null
fi
MP=${magpie_path:-/data/adb/magpie}

# 先校验，再创建 run 或打开日志。库不全时不做无人值守的写操作，也不改配置。
_NETLIB="$MODDIR/scripts/lib.sh"
[ -f "$_NETLIB" ] || { echo '! 缺少 scripts/lib.sh，已跳过开机自动操作' >&2; exit 1; }
. "$_NETLIB"
case "$(magpie_norm_path "$MP")" in
  ''|/|/data|/data/adb|/data/adb/modules|/data/adb/modules_update)
    echo "! magpie_path 不是独立的数据目录，已跳过开机自动操作：$MP" >&2; exit 1 ;;
esac

# 普通旧布局仍按原路径运行，不以安装白名单代替配置。日志重定向和轮转也不能
# 跟随链接；清理工具可能在开机等待或两轮巡检之间换掉 run，使用前再查。
boot_log_paths_safe() {
  magpie_path_unlinked "$MP/run" || return 1
  [ ! -e "$MP/run" ] || [ -d "$MP/run" ] || return 1
  for _log in "$MP/run/watchdog.log" "$MP/run/watchdog.log.1" "$MP/run/magpie.log" "$MP/run/magpie.log.1"; do
    [ ! -L "$_log" ] || return 1
    [ ! -e "$_log" ] || magpie_single_regular_file "$_log" || return 1
  done
}
# 修的只是已存在的可信组件；首次创建的 run 由 umask 077 保护。
magpie_harden_perms "$MP"
boot_log_paths_safe || { echo "! run 或日志不是无链接的普通路径，已跳过开机自动操作：$MP/run" >&2; exit 1; }

# 首次开机时必须先建 run，否则重定向失败、命令根本不会执行。
mkdir -p "$MP/run" 2>/dev/null
if [ -d "$MP/run" ]; then
  WATCH_LOG="$MP/run/watchdog.log"
else
  WATCH_LOG=/dev/null
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
    boot_module_active || return 1
    [ "$(date +%s)" -lt "$_deadline" ] || return 1
    sleep 3
  done
  return 0
}

# 只消费刷机时用户选装留下的标记。不在看门狗里轮询：一个独立任务负责整批
# 尝试（立即、再等 30 秒、再等 120 秒），无须网关本体，不阻塞服务启动或巡检。
install_pending_tile_app() (
  _tile_run="$MP/run"
  _tile_mod=$(CDPATH='' cd -P "$MODDIR" && pwd -P) || exit 0
  # fd 锁与清标记都相对于固定的 run；等待期间目录被换掉也不会操作新目标。
  magpie_path_unlinked "$_tile_run" && cd -P "$_tile_run" 2>/dev/null || exit 0
  _tile_dir_id=$(stat -c '%d:%i' .) || exit 0
  magpie_path_unlinked "$_tile_run" || exit 0
  _pending=./.tile_pending
  _lock=./.tile-install.flock
  _helper="$_tile_mod/scripts/tile-app.sh"
  tile_log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $1"; }
  boot_module_active || exit 0
  if [ ! -f "$_helper" ]; then
    if magpie_single_regular_file "$_pending"; then tile_log '缺少 scripts/tile-app.sh，保留补装标记'; fi
    exit 0
  fi
  . "$_helper"
  if ! magpie_single_regular_file "$_pending"; then
    # 未选装也可能已有 App 且选择过隐藏；只对账桌面图标，绝不安装。
    tile_reconcile_launcher .
    exit 0
  fi

  # 整批重试共用一个持久锁 inode；重复启动的 service.sh 不另开一批，不删锁文件。
  if ! magpie_pick_flock || [ -L "$_lock" ] || { [ -e "$_lock" ] && ! magpie_single_regular_file "$_lock"; }; then
    tile_log '磁贴补装锁不可用，保留标记，下次开机再试'; exit 1
  fi
  exec 8<>"$_lock" || exit 1
  magpie_flock -n 8 || exit 0
  # 已用完预算的 boot ID 记在锁内（固定 36 字节 + 换行），不改选装标记。
  # 无法取得 ID 时仍限本任务三次，不会永久抑制下次开机。
  _tile_boot=$(magpie_boot_id) || _tile_boot=''
  if [ -n "$_tile_boot" ] && [ "$(head -c 37 "$_lock")" = "$_tile_boot" ]; then exit 0; fi
  for _delay in 0 30 120; do
    if [ "$_delay" != 0 ]; then sleep "$_delay" 8>&- || exit 1; fi
    # 在锁内、每次实际安装前重查：安装意图可撤销，模块也可能在等待中被禁用或卸载。
    boot_module_active && magpie_path_unlinked "$_tile_run" &&
      [ "$(stat -c '%d:%i' "$_tile_run" 2>/dev/null)" = "$_tile_dir_id" ] &&
      magpie_single_regular_file "$_pending" || exit 0
    if tile_install "$_tile_mod" 8>&-; then
      if rm -f "$_pending"; then tile_log '磁贴 App 已补装'; else tile_log '磁贴 App 已补装，但未能清除补装标记'; fi
      # 覆盖安装可能把隐藏状态复位；延迟成功后也要重新落实一次。
      tile_reconcile_launcher . 8>&-
      exit 0
    fi
    if [ "$_delay" = 0 ]; then
      tile_log '磁贴 App 补装失败，将在本次开机再试至多两次'
      tile_reconcile_launcher . 8>&-
    fi
  done
  [ -z "$_tile_boot" ] || printf '%s\n' "$_tile_boot" >&8
  tile_log '磁贴 App 本次补装仍未成功，保留标记，下次开机再试'
)

# 把模块自带的那份配置复制到数据目录，供用户改。
#
# README 与 FAQ 都让用户改 /data/adb/magpie/scripts/magpie.config，
# 但以前没有任何地方创建它 —— 照文档做的用户第一步就撞上「文件不存在」。
#
# 只在不存时复制，已存在绝不动：用户改过的配置不能被模块更新覆盖。
# 先写临时文件再 mv，避免复制到一半被读到半份配置。
seed_user_config() {
  _dst="$MP/scripts/magpie.config"
  [ ! -e "$_dst" ] && [ ! -L "$_dst" ] && magpie_path_unlinked "$MP/scripts" || return 0
  _src="$MODDIR/scripts/magpie.config"
  [ -f "$_src" ] || return 0
  mkdir -p "$MP/scripts" 2>/dev/null || return 0
  _tmp=$(mktemp "$_dst.tmp.XXXXXX") || return 1
  # 不覆盖等待期间出现的旧配置；mktemp 的新文件本身就是 0600。
  if cat "$_src" > "$_tmp" && mv -nT "$_tmp" "$_dst" 2>/dev/null; then
    if [ ! -e "$_tmp" ]; then
      echo "$(date +'%Y-%m-%d %H:%M:%S') 已生成用户配置 $_dst" >>"$WATCH_LOG" 2>/dev/null
    else
      rm -f "$_tmp"
    fi
    return 0
  fi
  rm -f "$_tmp"
  return 1
}

# 开机后拉起服务，不阻塞启动流程
(
  wait_boot_completed
  # 等待期间模块可能被禁用（开机那几分钟足够点一下）
  boot_module_active || exit 0
  boot_log_paths_safe || { echo "! run 或日志已变更，取消开机自动操作：$MP/run" >&2; exit 1; }
  seed_user_config
  install_pending_tile_app >>"$WATCH_LOG" 2>&1 &
  rotate_log "$MP/run/magpie.log"
  # 启动日志留在看门狗日志里，否则开机时 stdout 直接丢弃
  sh "$MODDIR/scripts/magpie.service" auto-start >>"$WATCH_LOG" 2>&1
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

  # 与上面的首次拉起用同一段等待：不让看门狗在开机过程中抢先 start
  wait_boot_completed
  boot_module_active || exit 0

  while :; do
    sleep "$_wait"
    #<<< WATCHDOG-BODY（这行之后是循环体；tests/test-watchdog.sh 按标记抽取。
    #    sleep 留在标记外面：测试里 _wait 会按退避序列涨到几百秒，
    #    真睡下去会把测试拖成全量几分钟。）
    _wait=$WATCH_INTERVAL

    boot_module_active || exit 0
    # 补回消失的目录，但不跟随被替换的目录/日志链接写入、轮转或启动。
    boot_log_paths_safe || { echo "! run 或日志已变更，守护退出：$MP/run" >&2; exit 1; }
    [ -d "$MP/run" ] || mkdir -p "$MP/run" 2>/dev/null

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

    # 这是节流预判，不是启动授权；最终判断始终由控制器持锁重做。
    # 每轮只枚举一次进程：magpie_main_pid 对每个同名进程都要读 /proc，很贵。
    _pid=$(magpie_main_pid 2>/dev/null) || _pid=""
    if [ -z "$_pid" ] && ! magpie_stop_intent_current "$MP/run/.user_stopped"; then
      sh "$MODDIR/scripts/magpie.service" auto-start >>"$WATCH_LOG" 2>&1
      _watch_start_rc=$?
      if [ "$_watch_start_rc" -eq 0 ]; then
        _pid=$(magpie_main_pid 2>/dev/null) || _pid=""
        _now=$(date +%s)
        # 刚拉起又没了：多半起来就崩（端口冲突、配置错误），按失败退避，
        # 不能每 30 秒把 100 MB 的本体再拉一遍。
        if [ -n "${_last_start:-}" ] && [ $((_now - _last_start)) -lt $((WATCH_INTERVAL * 3)) ]; then
          _fail=$((_fail + 1))
          _wait=$WATCH_INTERVAL; _i=1
          while [ "$_i" -lt "$_fail" ] && [ "$_wait" -lt 600 ]; do _wait=$((_wait * 2)); _i=$((_i + 1)); done
          [ "$_wait" -gt 600 ] && _wait=600
          wlog "magpie 拉起后很快退出（连续 $_fail 次），$_wait 秒后再试；详见 $MP/run/magpie.log"
        else
          _fail=0
          wlog "magpie 未运行, 已尝试重新拉起"
        fi
        _last_start=$_now
      elif [ "$_watch_start_rc" -eq 2 ]; then
        # 用户停止，不是启动故障；不刷失败日志、不增加退避。
        _fail=0
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
    # 只和上一轮比：以前拿启动时写的 lan.url 当基准，地址 A→B→A 时第二次变化被漏掉，
    # 描述会一直停在 B。首轮（_last_lan 未初始化）只记录，不重复刷新启动时已写好的描述。
    if [ -n "$_pid" ]; then
      _cur_lan=$(lan_ip) || _cur_lan=""
      if [ "${_lan_seen:-0}" = 1 ] && [ "$_cur_lan" != "$_last_lan" ]; then
        wlog "局域网地址 ${_last_lan:-无} -> ${_cur_lan:-无}"
        sh "$MODDIR/scripts/status.sh" >/dev/null 2>&1
      fi
      _last_lan=$_cur_lan; _lan_seen=1
      # 某些省电模块会把 oom_score_adj 改回来；注释早就说要「改回来」，以前只在启动时做了一次。
      _oom=$(cat "/proc/$_pid/oom_score_adj" 2>/dev/null)
      if [ -n "$_oom" ] && [ "$_oom" != "-1000" ]; then
        echo -1000 > "/proc/$_pid/oom_score_adj" 2>/dev/null && wlog "oom_score_adj $_oom -> -1000"
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
    # 服务日志在运行期间也会长：启动前那次轮转管不到长期不重启的情况。
    if command -v magpie_truncate_log >/dev/null 2>&1 &&
       magpie_truncate_log "$MP/run/magpie.log" "$LOG_MAX_BYTES"; then
      wlog "magpie.log 超过 5MB，已归档为 magpie.log.1"
    fi
    #>>> WATCHDOG-BODY
  done
) &
