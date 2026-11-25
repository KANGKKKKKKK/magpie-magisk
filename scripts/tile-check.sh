#!/system/bin/sh
# 磁贴体检：输出若干 key=value 行。
#
# 给两个调用方共用：
#   - 磁贴 App 的「自查」按钮（MainActivity → SelfCheck）
#   - 模块的 doctor.sh [9/10]
# 两边都从这里取数，判定口径才不会各说各话。
#
# 只读。全程不改任何东西。

PKG=com.ruin.magpie.tile
COMP="$PKG/.MagpieTileService"

# ---- 模块 ----
if [ -d /data/adb/modules/magpie ]; then
  echo "mod=1"
else
  echo "mod=0"
fi

# ---- 服务 ----
# status 打印的是 "running (PID 123)" 或 "stopped"
_svc=$(sh /data/adb/modules/magpie/scripts/magpie.service status 2>/dev/null)
case "$_svc" in
  running*) echo "svc=running" ;;
  stopped*) echo "svc=stopped" ;;
  *)        echo "svc=unknown" ;;
esac

# ---- 装没装 / UID / 版本 ----
# 用 pm list --show-versioncode 而不是 pm dump：后者要 1 秒多，这个 130 毫秒，
# 而且能一次把 versionCode 和 uid 都带回来。
_line=$(pm list packages -U --show-versioncode "$PKG" 2>/dev/null | head -1)
_uid=$(printf '%s' "$_line" | sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p')
if [ -z "$_uid" ]; then
  echo "installed=0"
  exit 0
fi
_vcode=$(printf '%s' "$_line" | sed -n 's/.*versionCode:\([0-9][0-9]*\).*/\1/p')
echo "installed=1"
echo "uid=$_uid"
echo "vcode=$_vcode"

# ---- root 授权 ----
# 只有 Magisk 有 magisk --sqlite。KernelSU / APatch 下输出 absent，调用方跳过。
_pol=""
if command -v magisk >/dev/null 2>&1; then
  _pol=$(magisk --sqlite "SELECT policy FROM policies WHERE uid=$_uid;" 2>/dev/null \
    | sed -n 's/.*policy=\([0-9]*\).*/\1/p')
fi
echo "magisk=${_pol:-absent}"

# ---- 在不在控制中心 ----
case "$(settings get secure sysui_qs_tiles 2>/dev/null)" in
  *"custom($COMP)"*) echo "inqs=1" ;;
  *)                 echo "inqs=0" ;;
esac

# ---- 画的是什么 ----
# 取 secondaryLabel 而不是 tile.state：state 会把「已停止」和「启动失败」
# 压成同一个 1，把「需要 root」和「模块未安装」压成同一个 0。
_painted=$(dumpsys activity service com.android.systemui 2>/dev/null \
  | grep -o 'spec=custom(com\.ruin\.magpie\.tile[^)]*)[^]]*' \
  | sed -n 's/.*,secondaryLabel=\([^,]*\),.*/\1/p' | head -1)
echo "painted=$_painted"

# ---- 进程与冻结 ----
# 两个坑，都会把结论带偏：
#   1. uid_XXXX 目录里留着已死进程的 pid_* 目录；
#   2. 别的 uid 的进程也会挂进来（Chrome 沙箱 uid 90000 就在 10330 下面）。
# 所以必须回头核对 /proc/<pid>/cgroup，不能只看目录名。
_alive=0
_frozen=0
for _f in /sys/fs/cgroup/uid_"$_uid"/pid_*/cgroup.freeze; do
  [ -e "$_f" ] || continue
  _pid=${_f#/sys/fs/cgroup/uid_"$_uid"/pid_}
  _pid=${_pid%%/*}
  [ -d "/proc/$_pid" ] || continue
  case "$(sed -n 's/^0:://p' "/proc/$_pid/cgroup" 2>/dev/null)" in
    */uid_"$_uid"/pid_*) ;;
    *) continue ;;
  esac
  _alive=$((_alive + 1))
  [ "$(cat "$_f" 2>/dev/null)" = "1" ] && _frozen=$((_frozen + 1))
done
echo "alive=$_alive"
echo "frozen=$_frozen"

# ---- 疑似谁在冻 ----
# 不写死任何一家：只按场上有什么给线索，调用方决定怎么说。
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
