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
# 临时目录：Android 上没有 /tmp，退到 TMPDIR 或 /data/local/tmp
if [ -d /tmp ] && [ -w /tmp ]; then
  _TMPBASE=/tmp
else
  _TMPBASE=${TMPDIR:-/data/local/tmp}
fi
B=${TEST_BASE:-$_TMPBASE/magpie-service-test}
PASS=0; FAIL=0
KIDS=""

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

alive() { kill -0 "$1" 2>/dev/null; }

# 起一个占位进程顶替 magpie 子进程
sleeper() { sleep 300 >/dev/null 2>&1 & echo $!; }

# 按命令行匹配收进程：pkill 不一定在（模块脚本环境里常常没有），用 /proc 兜。
# 一条 grep 扫完所有 cmdline，不再逐个 pid 调 tr：真机上进程数以千计，
# 每次 reap 两次扫描、七个用例各扫一遍，逐个 fork 会把测试拖成好几分钟。
kill_matching() {
  for _d in $(grep -lF -- "$1" /proc/[0-9]*/cmdline 2>/dev/null); do
    _p=${_d#/proc/}
    _p=${_p%/cmdline}
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    [ "$_p" = "$$" ] && continue
    kill -9 "$_p" 2>/dev/null
  done
  return 0
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

echo "== 6 status.sh：端口写错时不写坏 JSON，并且认 MAGPIE_CONF"
build
# 这一节要真的跑 status.sh，不能用 build 里那个空壳
cp "$SRCDIR/scripts/status.sh" "$B/scripts/status.sh"
chmod 755 "$B/scripts/status.sh"
mkdir -p "$B/webroot"
J="$B/webroot/status.json"

# 漏端口：以前会写出 "apiPort": 127.0.0.1，整份 JSON 都读不出来
printf 'magpie_path="%s"\nMAGPIE_ADDR="127.0.0.1"\nMAGPIE_WEB_ADDR=""\n' "$B" > "$B/cfg"
MAGPIE_CONF="$B/cfg" sh "$B/scripts/status.sh" >/dev/null 2>&1
if grep -q '"apiPort": 0,' "$J" 2>/dev/null; then ok "端口非法时 apiPort 写成 0"
else bad "apiPort 不是 0：$(grep '"apiPort"' "$J" 2>/dev/null)"; fi
if grep -q '"configError": ".*端口' "$J" 2>/dev/null; then ok "给出了 configError 说明"
else bad "没有 configError：$(grep '"configError"' "$J" 2>/dev/null)"; fi
if grep -q '"apiUrl": ""' "$J" 2>/dev/null && grep -q '"lanApiUrl": ""' "$J" 2>/dev/null; then
  ok "没有编造 http://127.0.0.1:127.0.0.1 之类的地址"
else
  bad "地址字段仍在拼假地址：$(grep -E '"(apiUrl|lanApiUrl)"' "$J" 2>/dev/null | tr '\n' ' ')"
fi

# 合法配置：MAGPIE_CONF 要真的生效，端口跟着配置走
printf 'magpie_path="%s"\nMAGPIE_ADDR="127.0.0.1:3456"\nMAGPIE_WEB_ADDR=""\n' "$B" > "$B/cfg"
MAGPIE_CONF="$B/cfg" sh "$B/scripts/status.sh" >/dev/null 2>&1
if grep -q '"apiPort": 3456,' "$J" 2>/dev/null; then ok "MAGPIE_CONF 生效，端口用的是 3456"
else bad "配置没生效：$(grep '"apiPort"' "$J" 2>/dev/null)"; fi

echo "== 7 看门狗也要等开机：两条启动路径不会在开机过程中抢着 start"
# 静态断言：wait_boot_completed 必须出现在看门狗子 shell 里、循环之前。
# 这条拦的是「给首次拉起的子 shell 加了等待、忘了给看门狗加」。
_wd_line=$(grep -n '^# 看门狗' "$SRCDIR/service.sh" | head -1 | cut -d: -f1)
_boot_line=$(awk -v start="${_wd_line:-0}" 'NR > start && /wait_boot_completed/ { print NR; exit }' "$SRCDIR/service.sh")
_loop_line=$(awk -v start="${_wd_line:-0}" 'NR > start && /^  while :; do$/ { print NR; exit }' "$SRCDIR/service.sh")
if [ -z "$_wd_line" ] || [ -z "$_boot_line" ] || [ -z "$_loop_line" ]; then
  bad "定位失败（看门狗=${_wd_line:-?} 等待=${_boot_line:-?} 循环=${_loop_line:-?}）"
elif [ "$_boot_line" -lt "$_loop_line" ]; then
  ok "看门狗在进入循环前等待开机完成"
else
  bad "看门狗没等开机就开始巡检（等待在第 ${_boot_line:-?} 行，循环在第 $_loop_line 行）"
fi

# 运行期断言：getprop 一直报「还没开机完成」时，等满上限后仍要启动 ——
# 以前是无限 until，getprop 不可用时服务永远起不来。
build
# 启停脚本换成只记录调用的桩，这样「有没有拉起」完全由 calls.log 说话
printf '#!/bin/sh\necho "STUB service $*" >> %s/calls.log\nexit 0\n' "$B" > "$B/scripts/magpie.service"
chmod 755 "$B/scripts/magpie.service"
# getprop 一直报「还没开机完成」：等满上限后必须继续，不能永远卡住
mkdir -p "$B/stub"
printf '#!/bin/sh\nexit 0\n' > "$B/stub/getprop"
chmod 755 "$B/stub/getprop"
MAGPIE_BOOT_WAIT_SECS=2 PATH="$B/stub:$PATH" sh "$B/service.sh" >/dev/null 2>&1 &
SVC=$!
KIDS="$KIDS $SVC"
i=0
while [ "$i" -lt 40 ] && [ ! -s "$B/calls.log" ]; do
  sleep 0.2; i=$((i + 1))
done
if grep -q "STUB service start" "$B/calls.log" 2>/dev/null; then
  ok "等不到开机完成时超时后仍会启动（不会永远卡住）"
else
  bad "getprop 不报开机完成时服务一直没启动"
fi
reap

echo
echo "== 8 start：服务必须脱离调用者的会话"
# 这条拦的是一个真实事故：从管理器 [执行]、Termux、或任何「跑完就清理
# 子进程组」的宿主里 start，父进程一退出整组被收，服务表现为
# 「启动成功、二三十秒后自己没了」。修复靠 setsid。
if ! command -v setsid >/dev/null 2>&1; then
  echo "  SKIP  没有 setsid（服务会退回旧行为，不切会话）"
else
  build
  mkdir -p "$B/bin"
  # 进程判定全部打桩：沙箱与宿主共享 /proc，不打桩 start 会看到真实那个
  # magpie 并直接「已在运行」早退，测不到启动路径。
  stub_lib "magpie_main_pid() { return 1; }"
  stub_lib "magpie_all_pids() { return 0; }"
  # 假本体：记下自己的 pid 再顶住，方便回头查它的会话号
  printf '#!/bin/sh\necho $$ > %s/fake.pid\nexec sleep 200\n' "$B" > "$B/bin/magpie"
  chmod 755 "$B/bin/magpie"
  _my_sid=$(awk '{print $6}' /proc/$$/stat 2>/dev/null)

  # 只取 start 结果，不关心 --version 之类；6 秒就绪等待可以接受
  sh "$B/scripts/magpie.service" start >/dev/null 2>&1

  _fp=$(cat "$B/fake.pid" 2>/dev/null)
  sleep 0.5
  if [ -z "$_fp" ]; then
    bad "假本体没被启动（start 没跑到 launch）"
  else
    _fsid=$(awk '{print $6}' /proc/"$_fp"/stat 2>/dev/null)
    if [ -n "$_fsid" ] && [ "$_fsid" != "$_my_sid" ]; then
      ok "服务跑在独立会话里（sid=$_fsid，调用者 sid=$_my_sid）"
    else
      bad "服务仍在调用者的会话里（sid=${_fsid:-?}，调用者 $_my_sid），父进程退出就会被连带收掉"
    fi
    kill -9 "$_fp" 2>/dev/null
    pkill -f "$B/bin/magpie" 2>/dev/null
  fi
  rm -f "$B/fake.pid" "$B/data/certs/ca-bundle.crt"* 2>/dev/null
fi

echo
echo "== 9 toggle：在跑就停，没跑就起"
# 磁贴与快捷方式只给一个动作，所以 toggle 必须自己判断方向，
# 并且和 start/stop 走同一条路径（.user_stopped 语义不能丢）。
build
# 进程判定读 fake.pid：启动前文件不存在（=没在跑），起来后自然认得它。
# 这样 toggle 的两个方向都能在沙箱里走完整路径。
# 变量名必须避开脚本自己在用的 _p / _f / pid：那些是全局的，
# 被 pin_oom、cleanup_legacy_dnsmasq 改过之后，stub 会读到别人的值。
stub_lib "magpie_main_pid() { _stubf=\"$B/fake.pid\"; _stubp=\"\"; [ -s \"\$_stubf\" ] && _stubp=\$(cat \"\$_stubf\"); [ -n \"\$_stubp\" ] && [ -d \"/proc/\$_stubp\" ] && echo \"\$_stubp\"; }"
stub_lib "magpie_all_pids() { return 0; }"
mkdir -p "$B/bin"
printf '#!/bin/sh\necho $$ > %s/fake.pid\nexec sleep 200\n' "$B" > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"

# 情形一：没在跑 → 应该起来
_out=$(sh "$B/scripts/magpie.service" toggle 2>&1)
case "$_out" in
  *running*) ok "没在跑时 toggle 返回 running" ;;
  *) bad "没在跑时 toggle 输出不对：$_out" ;;
esac
_fp=$(cat "$B/fake.pid" 2>/dev/null)
[ -n "$_fp" ] && ok "确实把进程起来了" || bad "toggle 没有启动进程"
[ -f "$B/run/.user_stopped" ] && bad "启动后不该留 .user_stopped" || ok "启动清掉了停止标记"

# 情形二：在跑 → 应该停，并写下停止标记（进程判定已经是读 fake.pid，无需再打桩）
_out=$(sh "$B/scripts/magpie.service" toggle 2>&1)
case "$_out" in
  *stopped*) ok "在跑时 toggle 返回 stopped" ;;
  *) bad "在跑时 toggle 输出不对：$_out" ;;
esac
sleep 0.5
[ -d "/proc/$_fp" ] && bad "toggle 没停掉进程" || ok "进程已停"
[ -f "$B/run/.user_stopped" ] && ok "停止写了 .user_stopped（看门狗不会拉回）" \
  || bad "停止没写 .user_stopped，会被看门狗拉回来"
kill -9 "$_fp" 2>/dev/null


echo "== 10 web.key 权限与日志脱敏"
build
mkdir -p "$B/bin"
printf '#!/bin/sh\necho $$ > %s/fake.pid\nexec sleep 200\n' "$B" > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"
stub_lib "magpie_main_pid() { _stubf=\"$B/fake.pid\"; _stubp=\"\"; [ -s \"\$_stubf\" ] && _stubp=\$(cat \"\$_stubf\"); [ -n \"\$_stubp\" ] && [ -d \"/proc/\$_stubp\" ] && echo \"\$_stubp\"; }"
stub_lib "magpie_all_pids() { return 0; }"
stub_lib "magpie_mcp_pids() { return 0; }"
(umask 000; sh "$B/scripts/magpie.service" start >/dev/null 2>&1)
_mode=$(stat -c %a "$B/data/web.key" 2>/dev/null)
[ "$_mode" = 600 ] && ok "web.key 在宽松 umask 下仍为 600" || bad "web.key 权限为 $_mode"
if grep 'log Info "      WebUI' "$B/scripts/magpie.service" | grep -q '<redacted>'; then
  ok "启动日志不记录 ?k= 密钥"
else
  bad "启动日志仍可能泄露密钥"
fi
sh "$B/scripts/magpie.service" stop >/dev/null 2>&1 || true

echo "== 11 锁文件中的停止意图不会被 start 清除"
build
mkdir -p "$B/bin"
printf '#!/bin/sh\nexit 0\n' > "$B/bin/magpie"; chmod 755 "$B/bin/magpie"
stub_lib "magpie_main_pid() { return 1; }"
stub_lib "magpie_all_pids() { return 0; }"
stub_lib "magpie_mcp_pids() { return 0; }"
mkdir -p "$B/run/.service.lock"
# 存活的本测试进程充当锁持有者。
echo $$ > "$B/run/.service.lock/pid"
sh "$B/scripts/magpie.service" stop >/dev/null 2>&1 & _stop=$!
sleep 0.3
[ -f "$B/run/.user_stopped" ] && ok "等待锁时已写入停止标记" || bad "停止意图被锁延迟"
rm -rf "$B/run/.service.lock"
wait "$_stop"
[ -f "$B/run/.user_stopped" ] && ok "stop 完成后保留停止标记" || bad "stop 完成未保留停止标记"
[ ! -d "$B/run/.service.lock" ] && ok "启停锁最终释放" || bad "启停锁未释放"


echo "== 12 卸载 dnsmasq.keep.pid 必须校验进程身份"
_kp=$$
mkdir -p "$B/run"; echo "$_kp" > "$B/run/dnsmasq.keep.pid"
DATA="$B"; export DATA
# 抽出的卸载片段只能看到沙箱 PID；没有 fifo 身份时绝不能杀。
eval "$(sed -n '/^if \[ -f "\$DATA\/run\/dnsmasq.keep.pid" \]/,/^fi$/p' "$SRCDIR/uninstall.sh")"
if kill -0 "$_kp" 2>/dev/null; then ok "keep.pid 指向普通 sleep 时不误杀"; else bad "普通 sleep 被 keep.pid 误杀"; fi
eval "$(sed -n '/^kill_if_magpie()/,/^}/p' "$SRCDIR/uninstall.sh")"
if kill_if_magpie "$$"; then bad "非 magpie 进程通过身份校验"; else ok "非 magpie 进程被拒绝 kill"; fi

reap
echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
