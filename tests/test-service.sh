#!/bin/sh
# magpie.service / service.sh / magpie-cli.sh 的进程与目录行为测试
#
# 覆盖几处曾经出过问题的地方：
#   1. 首次开机 run 目录还没建时，service.sh 会不会因为重定向失败而根本不启动服务
#   2. stop 在主进程已经消失时，还会不会清掉 MCP 孤儿进程
#   3. 启动前只清 MCP 孤儿，不误杀用户手上正在跑的 magpie 命令
#   4. 自定义 magpie_path 时，`magpie` 命令会不会跑错目录
#
# 全程在临时目录里跑，进程判定用桩，不碰真实服务。
# 用法: sh tests/test-service.sh
#
# 注意：变量名一律 ASCII —— busybox ash / mksh 不支持多字节变量名
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRCDIR=${TEST_SRC_DIR:-$HERE/..}
B=${TEST_BASE:-/tmp/magpie-service-test}
PASS=0; FAIL=0
KIDS=""

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

alive() { kill -0 "$1" 2>/dev/null; }

# 起一个占位进程顶替 magpie 子进程
sleeper() { sleep 300 >/dev/null 2>&1 & echo $!; }

# 按命令行匹配收进程：pkill 不一定在（模块脚本环境里常常没有），用 /proc 兜
kill_matching() {
  for _d in /proc/[0-9]*; do
    _p=${_d#/proc/}
    [ "$_p" = "$$" ] && continue
    [ -r "$_d/cmdline" ] || continue
    _cl=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
    case "$_cl" in
      *"$1"*) kill -9 "$_p" 2>/dev/null ;;
    esac
  done
}

reap() {
  for _p in $KIDS; do kill -9 "$_p" 2>/dev/null; done
  kill_matching "$B/service.sh"
  kill_matching "$B/scripts/magpie.service"
  return 0
}
trap 'reap' EXIT INT TERM

build() {
  rm -rf "$B"; mkdir -p "$B/scripts" "$B/bin"
  # 两处 CONF 都改指沙箱，别读真实配置
  sed -e "s#^CONF=.*#CONF=$B/cfg#" \
      "$SRCDIR/scripts/magpie.service" > "$B/scripts/magpie.service"
  sed -e "s#^CONF=.*#CONF=$B/cfg#" -e "s#^MODDIR=.*#MODDIR=$B#" \
      "$SRCDIR/service.sh" > "$B/service.sh"
  printf 'magpie_path="%s"\n' "$B" > "$B/cfg"
  cp "$SRCDIR/scripts/lib.sh" "$B/scripts/lib.sh"
  printf '#!/bin/sh\nexit 0\n' > "$B/scripts/status.sh"
  chmod 755 "$B"/*.sh "$B"/scripts/*.sh
  : > "$B/calls.log"
}

# 往沙箱的 lib.sh 末尾追加桩函数
stub_lib() { printf '\n%s\n' "$1" >> "$B/scripts/lib.sh"; }

echo "== 1 首次开机：run 目录不存在时仍要拉起服务"
build
rm -rf "$B/run"
# 启停脚本换成只记录调用的桩，专注在「命令有没有被重定向吞掉」
printf '#!/bin/sh\necho "STUB service $*" >> %s/calls.log\nexit 0\n' "$B" > "$B/scripts/magpie.service"
chmod 755 "$B/scripts/magpie.service"
# service.sh 会等 getprop 报开机完成，这里打桩
mkdir -p "$B/stub"
printf '#!/bin/sh\necho 1\n' > "$B/stub/getprop"
chmod 755 "$B/stub/getprop"
PATH="$B/stub:$PATH" sh "$B/service.sh" >/dev/null 2>&1 &
SVC=$!
KIDS="$KIDS $SVC"
i=0
while [ "$i" -lt 20 ] && [ ! -s "$B/calls.log" ]; do
  sleep 0.2; i=$((i + 1))
done
[ -d "$B/run" ] && ok "自动建出了 run 目录" || bad "run 目录没建出来"
if grep -q "STUB service start" "$B/calls.log" 2>/dev/null; then
  ok "服务确实被拉起（重定向没把命令吞掉）"
else
  bad "服务没被拉起：$(cat "$B/calls.log" 2>/dev/null)"
fi
reap

echo
echo "== 2 stop：主进程已消失时仍清理 MCP 孤儿"
build
O1=$(sleeper); O2=$(sleeper)
KIDS="$KIDS $O1 $O2"
stub_lib "magpie_main_pid() { return 1; }
magpie_all_pids() { echo $O1 $O2; }
magpie_mcp_pids() { echo $O1 $O2; }"
out=$(sh "$B/scripts/magpie.service" stop 2>&1)
case "$out" in *"主进程未在运行"*) ok "如实报告主进程不在" ;; *) bad "报告不对：$out" ;; esac
if alive "$O1" || alive "$O2"; then bad "孤儿进程没清干净"; else ok "孤儿进程已清理"; fi
n=$(printf '%s\n' "$out" | grep -c "已收掉残留进程")
[ "$n" = "2" ] && ok "两条残留都记录了" || bad "记录条数不对：$n"

echo
echo "== 3 stop：主进程在时清主进程 + 孤儿"
build
MAIN=$(sleeper); ORPH=$(sleeper)
KIDS="$KIDS $MAIN $ORPH"
stub_lib "magpie_main_pid() { echo $MAIN; }
magpie_all_pids() { echo $MAIN $ORPH; }
magpie_mcp_pids() { echo $ORPH; }"
out=$(sh "$B/scripts/magpie.service" stop 2>&1)
case "$out" in *"正在停止"*) ok "报告了停止的主进程" ;; *) bad "没有停止记录：$out" ;; esac
if alive "$MAIN"; then bad "主进程还活着"; else ok "主进程已停"; fi
if alive "$ORPH"; then bad "孤儿还活着"; else ok "孤儿已清"; fi

echo
echo "== 4 start：只清 MCP 孤儿，不碰普通 magpie 命令"
build
MCP=$(sleeper); CLI=$(sleeper)
KIDS="$KIDS $MCP $CLI"
stub_lib "magpie_main_pid() { return 1; }
magpie_all_pids() { echo $MCP $CLI; }
magpie_mcp_pids() { echo $MCP; }"
# 假本体：起来了也不是 serve，start 会如实失败，这里只关心清理动作
printf '#!/bin/sh\nexit 1\n' > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"
sh "$B/scripts/magpie.service" start >/dev/null 2>&1
if alive "$MCP"; then bad "MCP 孤儿没被清"; else ok "启动前清了 MCP 孤儿"; fi
if alive "$CLI"; then ok "没有误杀普通 magpie 命令"; else bad "把普通命令也杀了"; fi
# 启动前会按 MAGPIE_DNS 生成 DNS 配置：Go 本体只认 /etc/resolv.conf
if [ -f "$B/run/resolv.conf" ] && grep -qx 'nameserver 223.5.5.5' "$B/run/resolv.conf" 2>/dev/null; then
  ok "按 MAGPIE_DNS 生成了 resolv.conf"
else
  bad "没有生成 resolv.conf"
fi
# 配置被写成空的时候不能把 DNS 弄没：Go 会退回 127.0.0.1:53，等于原生通道全断
printf 'magpie_path="%s"\nMAGPIE_DNS=""\n' "$B" > "$B/cfg"
sh "$B/scripts/magpie.service" start >/dev/null 2>&1
if grep -qx 'nameserver 223.5.5.5' "$B/run/resolv.conf" 2>/dev/null; then
  ok "MAGPIE_DNS 为空时保留了原有 DNS"
else
  bad "MAGPIE_DNS 为空时把 DNS 写坏了"
fi
printf 'magpie_path="%s"\n' "$B" > "$B/cfg"

echo
echo "== 5 自定义 magpie_path：magpie 命令跟着配置走"
build
mkdir -p "$B/custom/bin" "$B/custom/data"
printf '#!/bin/sh\necho "magpie 9.9.9 custom"\n' > "$B/custom/bin/magpie"
chmod 755 "$B/custom/bin/magpie"
printf 'magpie_path="%s"\n' "$B/custom" > "$B/cfg2"
MK="$B/module"
mkdir -p "$MK/scripts"
cp "$SRCDIR/scripts/lib.sh" "$MK/scripts/lib.sh"
# shebang 改成当前平台的 sh，才能直接执行（桌面没有 /system/bin/sh）
_sh=/bin/sh
[ -x /system/bin/sh ] && _sh=/system/bin/sh
sed -e "1s|.*|#!$_sh|" "$SRCDIR/scripts/magpie-cli.sh" > "$MK/scripts/magpie-cli.sh"
chmod 755 "$MK/scripts/magpie-cli.sh"
# 真实用法是经 PATH 里的软链调用，这里也走软链
mkdir -p "$B/link"
ln -sf "$MK/scripts/magpie-cli.sh" "$B/link/magpie"
out=$(MAGPIE_CONF="$B/cfg2" "$B/link/magpie" --version 2>&1)
case "$out" in *"9.9.9 custom"*) ok "命令读的是自定义数据目录" ;; *) bad "命令跑错目录：$out" ;; esac

reap
echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
