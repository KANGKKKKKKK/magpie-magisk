#!/system/bin/sh
# Magpie for Android - 卸载：彻底停服务并清掉所有产物

MODDIR=${0%/*}
DATA=/data/adb/magpie

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
  kill -15 $_pid 2>/dev/null
  sleep 1
  _pid=$(pidof magpie 2>/dev/null)
  [ -n "$_pid" ] && kill -9 $_pid 2>/dev/null
fi
for _n in magpie-bun; do
  _pid=$(pidof "$_n" 2>/dev/null)
  [ -n "$_pid" ] && kill -9 $_pid 2>/dev/null
done

# 4) 只收旧版监听 ::1:53 的 dnsmasq，不要动系统热点的 dnsmasq
if [ -f "$DATA/run/dnsmasq.pid" ]; then
  _dp=$(cat "$DATA/run/dnsmasq.pid" 2>/dev/null)
  case "$_dp" in
    ''|*[!0-9]*) : ;;
    *) grep -q 'listen-address=::1' "/proc/$_dp/cmdline" 2>/dev/null && kill -15 "$_dp" 2>/dev/null ;;
  esac
fi
[ -f "$DATA/run/dnsmasq.keep.pid" ] && kill -15 "$(cat "$DATA/run/dnsmasq.keep.pid" 2>/dev/null)" 2>/dev/null

echo "- Magpie 服务已停止"

# 5) 清掉装进 PATH 的 magpie 命令
for _p in /data/adb/ksu/bin /data/adb/magisk /data/adb/ap/bin; do
  [ -L "$_p/magpie" ] && rm -f "$_p/magpie" 2>/dev/null && echo "- 已移除 $_p/magpie"
done

# 6) 数据目录：设置、供应商、网关 key、用量记录、证书、日志、Bun 缓存全在里面
if [ -d "$DATA" ]; then
  _sz=$(du -sh "$DATA" 2>/dev/null | awk '{print $1}')
  rm -rf "$DATA"
  if [ -d "$DATA" ]; then
    echo "- 清理 $DATA 失败, 请手动删除"
  else
    echo "- 已清理 $DATA${_sz:+ ($_sz)}"
  fi
fi

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
