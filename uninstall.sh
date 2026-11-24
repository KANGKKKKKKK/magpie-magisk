#!/system/bin/sh
# Magpie for Android - 卸载：彻底停服务并清掉所有产物

MODDIR=${0%/*}

# 数据目录跟着配置走，否则自定义 magpie_path 的用户卸载后会留下一整套
# 二进制、配置、密钥和用量记录。查找顺序与其它脚本一致。
[ -f "$MODDIR/scripts/lib.sh" ] && . "$MODDIR/scripts/lib.sh" 2>/dev/null
command -v magpie_resolve_conf >/dev/null 2>&1 || magpie_resolve_conf() { return 1; }
magpie_path=/data/adb/magpie
_CONF=$(magpie_resolve_conf "$MODDIR" 2>/dev/null)
[ -n "$_CONF" ] && . "$_CONF" 2>/dev/null
DATA=${magpie_path:-/data/adb/magpie}

# rm -rf 之前先确认路径像话：配置写错一个字都不能变成删系统目录
# 能不能删这个路径。实现在 lib.sh（与 install.sh 共用同一份判断），
# 这里只做「lib.sh 缺失时的保守兜底」：一律不删。
# 宁可留下垃圾，也不能在缺库时 rm -rf 一个没校验过的路径。
cleanable() {
  if command -v magpie_path_cleanable >/dev/null 2>&1; then
    magpie_path_cleanable "$1"
    return $?
  fi
  echo "! lib.sh 缺失，拒绝删除任何路径（$1）" >&2
  return 1
}

# 先立标记，service.sh 的看门狗看到就不再把服务拉回来
: > "$MODDIR/.uninstalling" 2>/dev/null

# 1) 正常停服务（会写 .user_stopped）
[ -f "$MODDIR/scripts/magpie.service" ] && \
  sh "$MODDIR/scripts/magpie.service" stop >/dev/null 2>&1

# 2) 收掉看门狗子 shell：它是 sh 跑 service.sh 的常驻循环，杀 magpie 杀不到它
for _d in /proc/[0-9]*; do
  _p=${_d#/proc/}
  [ "$_p" = "$$" ] && continue
  [ -r "$_d/cmdline" ] || continue
  _cl=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
  # 只认带完整模块路径的，避免误杀命令行里恰好提到该名字的其它 shell
  case "$_cl" in
    *"$MODDIR/service.sh"*|*"/modules/magpie/service.sh"*) kill -9 "$_p" 2>/dev/null ;;
  esac
done

# 3) 兜底按进程名收尾（含插件用的 bun 子进程）
_pid=$(pidof magpie 2>/dev/null)
if [ -n "$_pid" ]; then
  # 这里**不能**加引号：pidof 返回的是空格分隔的多个 pid，
  # 加引号会把 "123 456" 当成一个 pid 传给 kill，一个都杀不掉。
  # shellcheck disable=SC2086
  kill -15 $_pid 2>/dev/null
  sleep 1
  _pid=$(pidof magpie 2>/dev/null)
  # shellcheck disable=SC2086
  [ -n "$_pid" ] && kill -9 $_pid 2>/dev/null
fi
# 进程名清单：现在只有一个，留成循环是为了以后加名字不用改结构
# shellcheck disable=SC2043
for _n in magpie-bun; do
  _pid=$(pidof "$_n" 2>/dev/null)
  # shellcheck disable=SC2086
  [ -n "$_pid" ] && kill -9 $_pid 2>/dev/null
done

# 3.5) 顺手卸掉磁贴 App（它只是本模块的配件，留着没有意义）。
#
# 不依赖 scripts/tile-app.sh：从管理器「移除模块」时，模块目录已经先被删了，
# 那时读不到那个脚本。这里直接按包名卸，一个包名而已，不需要 helper。
# （包名与 tile-app/AndroidManifest.xml 里的 package 必须一致。）
if command -v pm >/dev/null 2>&1; then
  if pm uninstall com.ruin.magpie.tile >/dev/null 2>&1; then
    echo "- 已卸载磁贴 App"
  fi
fi

# 4) 只收旧版监听 ::1:53 的 dnsmasq，不要动系统热点的 dnsmasq
if [ -f "$DATA/run/dnsmasq.pid" ]; then
  _dp=$(cat "$DATA/run/dnsmasq.pid" 2>/dev/null)
  case "$_dp" in
    ''|*[!0-9]*) : ;;
    *) grep -aq 'listen-address=::1' "/proc/$_dp/cmdline" 2>/dev/null && kill -15 "$_dp" 2>/dev/null ;;
  esac
fi
[ -f "$DATA/run/dnsmasq.keep.pid" ] && kill -15 "$(cat "$DATA/run/dnsmasq.keep.pid" 2>/dev/null)" 2>/dev/null

echo "- Magpie 服务已停止"

# 5) 清掉装进 PATH 的 magpie 命令
for _p in /data/adb/ksu/bin /data/adb/magisk /data/adb/ap/bin; do
  [ -L "$_p/magpie" ] && rm -f "$_p/magpie" 2>/dev/null && echo "- 已移除 $_p/magpie"
done

# 6) 数据目录：设置、供应商、网关 key、用量记录、证书、日志、Bun 缓存全在里面
#    自定义过 magpie_path 的话，默认目录里可能还有更早的残留，两个都清。
_seen=""
for _dir in "$DATA" /data/adb/magpie; do
  case " $_seen " in *" $_dir "*) continue ;; esac
  _seen="$_seen $_dir"
  [ -d "$_dir" ] || continue
  if ! cleanable "$_dir"; then
    echo "- 跳过可疑路径 $_dir, 请手动确认"
    continue
  fi
  _sz=$(du -sh "$_dir" 2>/dev/null | awk '{print $1}')
  rm -rf "$_dir"
  if [ -d "$_dir" ]; then
    echo "- 清理 $_dir 失败, 请手动删除"
  else
    echo "- 已清理 $_dir${_sz:+ ($_sz)}"
  fi
done

# 7) 面板文件里有网关 key，模块目录若残留也一并清掉
rm -f "$MODDIR/webroot/status.json" "$MODDIR/webroot/lastlog.txt" 2>/dev/null

# 8) 复查
_left=""
pidof magpie >/dev/null 2>&1 && _left="$_left magpie进程"
[ -d "$DATA" ] && _left="$_left $DATA"
if [ -n "$_left" ]; then
  echo "- 仍有残留:$_left"
else
  echo "- 卸载完成, 无残留"
fi
