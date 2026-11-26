#!/system/bin/sh
# 磁贴体检：输出 key=value 行，正常取数完成后最后输出 done=1。
# 给磁贴 App（MainActivity → SelfCheck）与 doctor.sh [9/10] 共用。
# 只读；unknown 表示取数失败/不可用，绝不能冒充 0（未安装/未冻结）。
# done 仅表示协议完整，不表示每项检测成功；可选的 Magisk/sqlite 无需安装。

PKG=com.ruin.magpie.tile
COMP="$PKG/.MagpieTileService"

# ---- 模块 ----
if [ -d /data/adb/modules/magpie ]; then
  echo "mod=1"
elif [ -r /data/adb/modules ] && [ -x /data/adb/modules ]; then
  echo "mod=0"
else
  echo "mod=unknown"
fi

# ---- 服务 ----
# 失败退出即使留下了类似 stopped 的文本也不能当作有效状态。
_svc_state=unknown
if _svc=$(sh /data/adb/modules/magpie/scripts/magpie.service status 2>/dev/null); then
  case "$_svc" in
    'running (PID '[0-9]*')') _svc_state=running ;;
    stopped) _svc_state=stopped ;;
  esac
fi
echo "svc=$_svc_state"

# ---- 装没装 / UID / 版本 ----
# 不把 pm 失败或畸形输出当成未安装，也不匹配包名相似的别的 App。
if ! _packages=$(pm list packages -U --show-versioncode "$PKG" 2>/dev/null); then
  echo "installed=unknown"
  echo "done=1"
  exit 0
fi
_line=$(printf '%s\n' "$_packages" | while IFS= read -r _entry; do
  if [ "${_entry%% *}" = "package:$PKG" ]; then
    printf '%s\n' "$_entry"
    break
  fi
done)
if [ -z "$_line" ]; then
  # 空结果或仅有其他包名才是确定未安装；pm 的错误文本不是成功结果。
  case "$_packages" in
    ''|package:*) echo "installed=0" ;;
    *) echo "installed=unknown" ;;
  esac
  echo "done=1"
  exit 0
fi
_uid=$(printf '%s' "$_line" | sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p')
if [ -z "$_uid" ]; then
  echo "installed=unknown"
  echo "done=1"
  exit 0
fi
_vcode=$(printf '%s' "$_line" | sed -n 's/.*versionCode:\([0-9][0-9]*\).*/\1/p')
echo "installed=1"
echo "uid=$_uid"
echo "vcode=${_vcode:-unknown}"

# ---- root 授权 ----
# 只有 Magisk 支持 --sqlite；KernelSU / APatch 或查询失败时保留 unknown。
_pol=unknown
if command -v magisk >/dev/null 2>&1 &&
   _sql=$(magisk --sqlite "SELECT policy FROM policies WHERE uid=$_uid;" 2>/dev/null); then
  _policy=$(printf '%s\n' "$_sql" | sed -n 's/.*policy=\([0-9][0-9]*\).*/\1/p' | head -1)
  case "$_policy" in 0|1|2) _pol=$_policy ;; esac
fi
echo "magisk=$_pol"

# ---- 在不在控制中心 ----
_inqs=unknown
if _qs=$(settings get secure sysui_qs_tiles 2>/dev/null); then
  case "$_qs" in
    *"custom($COMP)"*) _inqs=1 ;;
    ''|Error*|Exception*|*SecurityException*) : ;;
    *) _inqs=0 ;;
  esac
fi
echo "inqs=$_inqs"

# ---- 画的是什么 ----
# 取 secondaryLabel 而不是 tile.state：后者会把多个故障压成同一个状态。
_painted=unknown
if _dump=$(dumpsys activity service com.android.systemui 2>/dev/null); then
  _painted=$(printf '%s\n' "$_dump" \
    | grep -o 'spec=custom(com\.ruin\.magpie\.tile[^)]*)[^]]*' \
    | sed -n 's/.*,secondaryLabel=\([^,]*\),.*/\1/p' | head -1)
fi
echo "painted=$_painted"

# ---- 进程与冻结 ----
# cgroup 中可留有死 PID，甚至混入其他 UID 的沙箱进程；逐个核对 /proc。
# 无法枚举 / 读取 / 识别 cgroup v2 时必须 unknown，而不是「0 个未冻结」。
_alive=unknown
_frozen=unknown
_cgdir=/sys/fs/cgroup/uid_"$_uid"
if [ -r /proc ] && [ -x /proc ] && [ -d "$_cgdir" ] &&
   [ -r "$_cgdir" ] && [ -x "$_cgdir" ] && ls "$_cgdir" >/dev/null 2>&1; then
  _alive=0
  _frozen=0
  _proc_unknown=0
  _freeze_unknown=0
  for _cgpid in "$_cgdir"/pid_*; do
    [ -d "$_cgpid" ] || continue
    _pid=${_cgpid##*/pid_}
    case "$_pid" in ''|*[!0-9]*) _proc_unknown=1; continue ;; esac
    [ -d "/proc/$_pid" ] || continue
    if ! _pcg=$(cat "/proc/$_pid/cgroup" 2>/dev/null); then
      _proc_unknown=1
      continue
    fi
    _unified=$(printf '%s\n' "$_pcg" | sed -n 's/^0:://p')
    case "$_unified" in
      */uid_"$_uid"/pid_"$_pid") ;;
      '') _proc_unknown=1; continue ;;
      *) continue ;;
    esac
    _alive=$((_alive + 1))
    if _freeze=$(cat "$_cgpid/cgroup.freeze" 2>/dev/null); then
      case "$_freeze" in
        1) _frozen=$((_frozen + 1)) ;;
        0) : ;;
        *) _freeze_unknown=1 ;;
      esac
    else
      _freeze_unknown=1
    fi
  done
  if [ "$_proc_unknown" = 1 ]; then
    _alive=unknown
    _frozen=unknown
  elif [ "$_freeze_unknown" = 1 ]; then
    _frozen=unknown
  fi
fi
echo "alive=$_alive"
echo "frozen=$_frozen"

# ---- 疑似谁在冻 ----
# 不写死任何一家，只按场上有什么提供线索。
_who=""
for _d in /data/system/NoActive_*; do
  [ -d "$_d" ] && { _who=NoActive; break; }
done
if [ -z "$_who" ] && [ -f /data/system/czero_freeze_list.txt ]; then
  _who=CZero
fi
if [ -z "$_who" ] && [ "$(settings get global cached_apps_freezer 2>/dev/null)" = "enabled" ]; then
  _who=system
fi
if [ -z "$_who" ] && service check greezer 2>/dev/null | grep -q found; then
  _who=greezer
fi
echo "freezer=$_who"
echo "done=1"
