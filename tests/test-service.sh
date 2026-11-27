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
  KIDS=""
  kill_matching "$B/service.sh"
  kill_matching "$B/scripts/magpie.service"
  return 0
}
trap 'reap' EXIT INT TERM

build() {
  rm -rf "$B"; mkdir -p "$B/scripts" "$B/bin"
  # 两处 CONF 都改指沙箱，别读真实配置
  sed -e "s#^CONF=.*#CONF=$B/cfg#" \
      "$SRCDIR/scripts/magpie.service" | awk '
      /^# 每条 start\/stop 路径/ {
        # 生命周期用例用 sleep 冒充本体；精确 /proc 分类器另在第 21 节测试。
        print "service_pid_command() { kill -0 \"$1\" 2>/dev/null; }"
        print "pin_oom() { return 0; }"
        print "ensure_cli() { return 0; }"
      }
      { print }
    ' > "$B/scripts/magpie.service"
  sed -e "s#^CONF=.*#CONF=$B/cfg#" -e "s#^MODDIR=.*#MODDIR=$B#" \
      "$SRCDIR/service.sh" > "$B/service.sh"
  printf 'magpie_path="%s"\n' "$B" > "$B/cfg"
  cp "$SRCDIR/scripts/lib.sh" "$B/scripts/lib.sh"
  # 默认绝不扫描宿主进程；需要进程的用例只返回自己创建的 PID。
  printf '\npidof() { return 1; }\nmagpie_main_pid() { return 1; }\nmagpie_all_pids() { return 0; }\nmagpie_mcp_pids() { return 0; }\n' >> "$B/scripts/lib.sh"
  # 旧生命周期夹具的候选来自桩，新的全量 serve API 也不能扫描宿主。
  printf '%s\n' 'magpie_command_pids() { case "$1" in serve) magpie_main_pid ;; mcp) magpie_mcp_pids ;; *) return 1 ;; esac; }' >> "$B/scripts/lib.sh"
  printf '#!/bin/sh\nexit 0\n' > "$B/scripts/status.sh"
  chmod 755 "$B"/*.sh "$B"/scripts/*.sh
  : > "$B/calls.log"
}

# 往沙箱的 lib.sh 末尾追加桩函数
stub_lib() { printf '\n%s\n' "$1" >> "$B/scripts/lib.sh"; }

wait_file() {
  _wait_i=0
  while [ "$_wait_i" -lt 100 ]; do
    [ -f "$1" ] && return 0
    sleep 0.05; _wait_i=$((_wait_i + 1))
  done
  return 1
}
lock_available() (
  . "$SRCDIR/scripts/lib.sh"
  magpie_pick_flock || exit 1
  exec 7>>"$B/run/.service.flock"
  magpie_flock -n 7
)

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
if grep -q "STUB service auto-start" "$B/calls.log" 2>/dev/null; then
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
magpie_mcp_pids() { for _mock_pid in $O1 $O2; do kill -0 \"\$_mock_pid\" 2>/dev/null && echo \"\$_mock_pid\"; done; }"
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
stub_lib "magpie_main_pid() { kill -0 $MAIN 2>/dev/null && echo $MAIN; }
magpie_all_pids() { echo $MAIN $ORPH; }
magpie_mcp_pids() { kill -0 $ORPH 2>/dev/null && echo $ORPH; }"
out=$(sh "$B/scripts/magpie.service" stop 2>&1)
case "$out" in *"正在停止"*) ok "报告了停止的主进程" ;; *) bad "没有停止记录：$out" ;; esac
if alive "$MAIN"; then bad "主进程还活着"; else ok "主进程已停"; fi
if alive "$ORPH"; then bad "孤儿还活着"; else ok "孤儿已清"; fi

echo
echo "== 4a 卸载及禁用标记要阻止所有新启动，不能阻止 stop"
for _gate in .uninstalling disable; do
  build
  printf '#!/bin/sh\nprintf started > "%s/launched"\n' "$B" > "$B/bin/magpie"
  chmod 755 "$B/bin/magpie"
  : > "$B/$_gate"
  for _entry in start restart toggle; do
    _out=$(sh "$B/scripts/magpie.service" "$_entry" 2>&1); _rc=$?
    case "$_rc:$_out" in
      0:*) bad "$_gate 未阻止 $_entry" ;;
      *拒绝启动*) [ ! -e "$B/launched" ] && ok "$_gate 阻止 $_entry" || bad "$_entry 仍执行了本体" ;;
      *) bad "$_entry 未报告维护或禁用：$_out" ;;
    esac
  done
  if sh "$B/scripts/magpie.service" stop >/dev/null 2>&1; then ok "$_gate 下仍允许 stop"; else bad "$_gate 阻止了清理"; fi
done

echo "== 4b 旧数据位于模块树时明确告警，不宣称已保留"
build
mkdir -p "$B/legacy-data"
printf 'magpie_path="%s"\n' "$B/legacy-data" > "$B/cfg"
printf '#!/bin/sh\n[ "$1" = stop ]\n' > "$B/scripts/magpie.service"
# 就算守卫失效，模拟脚本也不允许读系统进程、卸载 App 或清理真实目录。
sed -e "s#/proc/#$B/proc/#g" -e "s#/data/adb/#$B/fake-adb/#g" \
    "$SRCDIR/uninstall.sh" > "$B/uninstall.sh"
stub_lib "magpie_resolve_conf() { printf '%s\\n' '$B/cfg'; }
kill() { : > '$B/unsafe'; return 1; }
pm() { : > '$B/unsafe'; return 1; }"
_out=$(sh "$B/uninstall.sh" 2>&1); _rc=$?
case "$_rc:$_out" in
  0:*) bad "旧模块内数据布局误报卸载成功" ;;
  *不能保证数据保留*) [ -d "$B/legacy-data" ] && [ ! -e "$B/unsafe" ] && ok "警告后停止，未清理旧布局" || bad "不应清理旧布局" ;;
  *) bad "未明确说明管理器可能删除数据：$_out" ;;
esac

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
mkdir -p "$B/data" "$B/run"
printf 'web-password-sentinel-1234567890\n' > "$B/data/web.key"
printf 'http://127.0.0.1:3430/?k=web-password-sentinel-1234567890\n' > "$B/run/web.url"
printf 'request ?k=web-password-sentinel-1234567890 Bearer abcdefghijklmnop sk-1234567890secret\n' > "$B/run/magpie.log"
MAGPIE_CONF="$B/cfg" sh "$B/scripts/status.sh" >/dev/null 2>&1
if grep -Eq 'apiKey|webKey|webUrlKey|web-password-sentinel|sk-1234567890secret' "$J"; then bad "状态 JSON 含秘密或密码链接"; else ok "状态 JSON 不含长期密钥或带密码 URL"; fi
if grep -Eq 'web-password-sentinel|sk-1234567890secret|Bearer abcdefghijklmnop' "$B/webroot/lastlog.txt"; then bad "公开日志快照未脱敏"; else ok "WebUI 日志快照遮盖常见 URL/Bearer/API key"; fi
if grep -Eq 'webUrlKey|d\.webUrlKey|window\.open|href = d\.webUrl' "$SRCDIR/webroot/index.html"; then bad "模块 WebView 仍有面板导航链接"; else ok "模块 WebView 不导航到面板，也不携带密码链接"; fi

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
if grep -q "STUB service auto-start" "$B/calls.log" 2>/dev/null; then
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
stub_lib 'magpie_port_rows() { return 1; }'
_out=$(sh "$B/scripts/magpie.service" panel-url 2>&1); _rc=$?
[ "$_rc" -ne 0 ] && [ -z "$_out" ] && ok "只有进程、没有监听归属证据时不提供地址" || bad "panel-url 根据 PID 猜了地址：$_out"
[ ! -e "$B/run/web.url" ] && ok "不再创建含访问密钥的 web.url 副本" || bad "旧凭据 URL 缓存仍存在"

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
mkdir -p "$B/run"
. "$SRCDIR/scripts/lib.sh"
magpie_pick_flock || exit 1
exec 7>>"$B/run/.service.flock"
magpie_flock -n 7 || exit 1
sh "$B/scripts/magpie.service" stop 7>&- >"$B/stop.log" 2>&1 & _stop=$!
KIDS="$KIDS $_stop"
wait_file "$B/run/.stop-request.$_stop" && wait_file "$B/run/.user_stopped" || bad "stop 未在锁等待前发布意图"
[ -f "$B/run/.user_stopped" ] && ok "等待锁时已写入停止标记" || bad "停止意图被锁延迟"
magpie_flock -u 7; exec 7>&-
wait "$_stop"
[ -f "$B/run/.user_stopped" ] && ok "stop 完成后保留停止标记" || bad "stop 完成未保留停止标记"
lock_available && ok "启停锁最终释放且锁文件保留" || bad "启停锁未释放"


echo "== 12 卸载 dnsmasq.keep.pid 必须校验进程身份"
_kp=$$
mkdir -p "$B/run"; echo "$_kp" > "$B/run/dnsmasq.keep.pid"
DATA="$B"; export DATA
# 抽出的卸载片段只能看到沙箱 PID；没有 fifo 身份时绝不能杀。
eval "$(sed -n '/^if \[ -f "\$DATA\/run\/dnsmasq.keep.pid" \]/,/^fi$/p' "$SRCDIR/uninstall.sh")"
if kill -0 "$_kp" 2>/dev/null; then ok "keep.pid 指向普通 sleep 时不误杀"; else bad "普通 sleep 被 keep.pid 误杀"; fi
if grep -q '^kill_if_magpie()' "$SRCDIR/uninstall.sh"; then
  bad "卸载器不应保留模糊兜底进程终止函数"
else
  ok "卸载器不再使用模糊兜底进程终止函数"
fi
if grep -q 'pidof magpie-bun' "$SRCDIR/uninstall.sh"; then bad "卸载器仍按宽泛 magpie-bun 名称兜底杀进程"; else ok "卸载器不再按宽泛进程名兜底杀进程"; fi
if grep -Fq 'rm -rf "$DATA"' "$SRCDIR/uninstall.sh" || grep -Fq 'rm -rf "$_dir"' "$SRCDIR/uninstall.sh"; then bad "卸载器仍递归删除用户数据"; else ok "卸载器不递归删除用户数据"; fi
if grep -q '服务停止失败' "$SRCDIR/uninstall.sh" && grep -q '保留用户数据并中止清理' "$SRCDIR/uninstall.sh"; then ok "停止失败时保留数据并中止清理"; else bad "卸载停止失败未失败关闭"; fi

reap
echo
echo "== 13 两个过期目录锁回收竞争者仍由同一内核锁串行执行"
build
mkdir -p "$B/run/.service.lock"
echo 999999 > "$B/run/.service.lock/pid"
echo 1 > "$B/run/.service.lock/starttime"
: > "$B/run/.service.flock"
_inode=$(stat -c '%d:%i' "$B/run/.service.flock")
# 运行时加载生产函数，不在测试中维护第二份锁算法。
{
  printf '. "%s/scripts/lib.sh"\n' "$B"
  sed -n '/^acquire_service_lock() {/,/^}/p; /^release_service_lock() {/,/^}/p' "$SRCDIR/scripts/magpie.service"
  cat <<'WORKER'
RUN=$1; SERVICE_LOCK="$RUN/.service.flock"
log() { echo "$*" >&2; }
trap release_service_lock EXIT
trap 'exit 143' TERM
: > "$RUN/ready.$2"
while [ ! -f "$RUN/go" ]; do sleep 0.01; done
acquire_service_lock || exit 1
mkdir "$RUN/critical" 2>/dev/null || : > "$RUN/overlap"
echo "$2" >> "$RUN/entries"
sleep 0.2
rmdir "$RUN/critical" 2>/dev/null || :
release_service_lock
WORKER
} > "$B/worker.sh"
sh "$B/worker.sh" "$B/run" a & _a=$!
sh "$B/worker.sh" "$B/run" b & _b=$!
KIDS="$KIDS $_a $_b"
wait_file "$B/run/ready.a" && wait_file "$B/run/ready.b" || bad "锁竞争者没有就绪"
: > "$B/run/go"
wait "$_a"; _ar=$?; wait "$_b"; _br=$?
[ "$_ar:$_br" = 0:0 ] && ok "两个 stale-lock 竞争者都完成" || bad "竞争者失败：$_ar:$_br"
[ ! -e "$B/run/overlap" ] && [ "$(wc -l < "$B/run/entries")" -eq 2 ] && ok "竞争者临界区从不重叠" || bad "竞争者并行或未进入"
[ "$(stat -c '%d:%i' "$B/run/.service.flock")" = "$_inode" ] && ok "持久 flock inode 从未替换或删除" || bad "flock inode 分叉"
[ "$(cat "$B/run/.service.lock/pid")" = 999999 ] && ok "旧目录仅作元信息，不执行不安全回收" || bad "旧目录被回收"

echo "== 14 restart 收到 TERM 返回 143，绝不继续 start"
build
stub_lib "pidof() { : > \"$B/stop-entered\"; sleep 0.4; return 1; }"
printf '#!/bin/sh\n: > "%s/start-sentinel"\nexit 0\n' "$B" > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"
sh "$B/scripts/magpie.service" restart >"$B/restart.log" 2>&1 & _rp=$!
KIDS="$KIDS $_rp"
wait_file "$B/stop-entered" || bad "restart 未进入 stop 临界区"
if lock_available; then bad "restart 临界区没有持锁"; else ok "restart 临界区确实持锁"; fi
kill -TERM "$_rp" 2>/dev/null
wait "$_rp" 2>/dev/null; _rc=$?
[ "$_rc" -eq 143 ] && ok "TERM 返回 143" || bad "TERM 退出码为 $_rc"
[ ! -f "$B/start-sentinel" ] && ok "TERM 后绝不启动本体" || bad "释放锁后仍启动了本体"
lock_available && ok "TERM 后内核锁可立即重取" || bad "TERM 后锁未释放"
if ls "$B/run"/.stop-request.* >/dev/null 2>&1; then bad "信号中断后残留停止请求"; else ok "信号清理了停止请求"; fi

echo "== 15 open/flock 半初始化窗口被 TERM 打断也不会留下锁"
for _phase in before after; do
  build
  # 包裹真实生产 flock 转发函数，只在系统调用前/返回后精确注入信号。
  sed -n '/^magpie_flock() {/,/^}/p' "$SRCDIR/scripts/lib.sh" | sed '1s/magpie_flock/kernel_flock/' >> "$B/scripts/lib.sh"
  stub_lib "magpie_flock() {
    if [ \"\$1\" = -n ] && [ \"$_phase\" = before ]; then kill -TERM \$\$; fi
    kernel_flock \"\$@\"; _kernel_rc=\$?
    if [ \"\$1\" = -n ] && [ \"$_phase\" = after ]; then kill -TERM \$\$; fi
    return \"\$_kernel_rc\"
  }"
  stub_lib "magpie_main_pid() { : > \"$B/start-sentinel\"; return 1; }"
  sh "$B/scripts/magpie.service" start >"$B/half.log" 2>&1; _rc=$?
  [ "$_rc" -eq 143 ] && ok "$_phase flock 窗口 TERM 返回 143" || bad "$_phase 窗口未被信号中止：$_rc"
  lock_available && [ ! -f "$B/start-sentinel" ] && ok "$_phase 半初始化无死锁且未进入 start" || bad "$_phase 半初始化遗留锁或继续运行"
done

echo "== 16 并发 start/stop：后来的 stop 不越过持锁 start"
build
stub_lib "pidof() {
  [ \"\$1\" = dnsmasq ] || return 1
  mkdir \"$B/critical\" 2>/dev/null || : > \"$B/overlap\"
  echo \$\$ >> \"$B/entries\"
  : > \"$B/entered.\$\$\"
  while [ ! -f \"$B/release-first\" ]; do sleep 0.05; done
  rmdir \"$B/critical\" 2>/dev/null || :
  return 1
}"
sh "$B/scripts/magpie.service" start >"$B/start.log" 2>&1 & _sp=$!
KIDS="$KIDS $_sp"
wait_file "$B/entered.$_sp" || bad "start 未进入临界区"
sh "$B/scripts/magpie.service" stop >"$B/stop.log" 2>&1 & _tp=$!
KIDS="$KIDS $_tp"
wait_file "$B/run/.stop-request.$_tp" || bad "stop 没写入等待标记"
sleep 0.2
[ ! -f "$B/entered.$_tp" ] && ok "stop 在 start 临界区外等待" || bad "stop 越过持锁 start"
: > "$B/release-first"
wait "$_sp"; wait "$_tp"; _rc=$?
[ "$_rc" -eq 0 ] && [ "$(wc -l < "$B/entries")" -eq 2 ] && [ ! -e "$B/overlap" ] && ok "start/stop 串行完成，无临界区重叠" || bad "并发 start/stop 失败或重叠"
[ -f "$B/run/.user_stopped" ] && lock_available && ok "最终停止意图保留且锁可重取" || bad "停止意图或锁状态错误"

echo "== 17 daemon 不继承锁；控制器被 SIGKILL 也不永久持锁"
build
printf '#!/bin/sh\necho $$ > "%s/fake.pid"\nexec sleep 60\n' "$B" > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"
sh "$B/scripts/magpie.service" start >"$B/start.log" 2>&1 & _ctl=$!
KIDS="$KIDS $_ctl"
wait_file "$B/fake.pid" || bad "沙箱 daemon 没有启动"
_fake=$(cat "$B/fake.pid" 2>/dev/null)
kill -KILL "$_ctl" 2>/dev/null; wait "$_ctl" 2>/dev/null || :
# 短命的就绪轮询 sleep 最多还活 0.5 秒；daemon 必须完全没有锁 FD。
sleep 0.7
if [ -n "$_fake" ] && kill -0 "$_fake" 2>/dev/null && lock_available; then
  ok "SIGKILL 控制器后，活 daemon 不会占锁"
else
  bad "daemon 继承锁或未存活"
fi
if [ -n "$_fake" ] && [ ! -e "/proc/$_fake/fd/9" ]; then ok "daemon 的锁 FD 已关闭"; else bad "daemon 仍继承 FD 9"; fi
[ -z "$_fake" ] || kill -KILL "$_fake" 2>/dev/null

echo "== 18 新锁路径链接拒绝；缺少 flock 时失败关闭"
build
mkdir -p "$B/run"; printf sentinel > "$B/outside"
ln -s "$B/outside" "$B/run/.service.flock"
_out=$(sh "$B/scripts/magpie.service" stop 2>&1); _rc=$?
[ "$_rc" -ne 0 ] && [ "$(cat "$B/outside")" = sentinel ] && ok "拒绝 flock 符号链接，不改外部文件" || bad "flock 链接未拒绝：$_out"
build
stub_lib 'magpie_pick_flock() { return 1; }'
_out=$(sh "$B/scripts/magpie.service" stop 2>&1); _rc=$?
case "$_rc:$_out" in 1:*缺少可用的*flock*) ok "没有 flock 时明确失败，不回退目录抢锁" ;; *) bad "缺少 flock 未安全拒绝：$_rc $_out" ;; esac

echo "== 19 等待启停锁时 TERM 退出，不能释放别人的锁或进入 start"
build
mkdir -p "$B/run"
. "$SRCDIR/scripts/lib.sh"
magpie_pick_flock || exit 1
exec 7>>"$B/run/.service.flock"
magpie_flock -n 7 || exit 1
stub_lib "magpie_main_pid() { : > \"$B/start-sentinel\"; return 1; }"
sh "$B/scripts/magpie.service" start 7>&- >"$B/wait.log" 2>&1 & _wp=$!
KIDS="$KIDS $_wp"
wait_file "/proc/$_wp/fd/9" || bad "start 未打开等待锁 FD"
kill -TERM "$_wp" 2>/dev/null
wait "$_wp" 2>/dev/null; _rc=$?
[ "$_rc" -eq 143 ] && [ ! -f "$B/start-sentinel" ] && ok "等锁时 TERM 返回 143 且不执行 start" || bad "等锁信号处理错误：$_rc"
if lock_available; then bad "等待者退出释放了别人的锁"; else ok "等待者退出不会解锁当前持有者"; fi
# 加速轮询而不改变生产锁函数，确认达到有限次数后拒绝进入临界区。
stub_lib 'sleep() { :; }'
_out=$(sh "$B/scripts/magpie.service" start 7>&- 2>&1); _rc=$?
case "$_rc:$_out" in 1:*另一个启停操作仍在进行*) ok "有限轮询耗尽后拒绝启动" ;; *) bad "启停锁没有有界失败：$_rc $_out" ;; esac
magpie_flock -u 7; exec 7>&-
lock_available && ok "原持有者退出后锁正常可用" || bad "原持有者释放后仍被卡住"

reap

echo "== 20 status 完全只读：不建目录、不创建密钥、不改 pidfile 或权限"
build
_out=$(sh "$B/scripts/magpie.service" status 2>&1); _rc=$?
[ "$_rc:$_out" = 0:stopped ] && ok "空目录 status 正确返回 stopped" || bad "空目录 status 输出错误"
[ ! -e "$B/run" ] && [ ! -e "$B/data" ] && ok "status 不初始化 run/data 或 web.key" || bad "status 创建了目录或密钥"
mkdir -p "$B/run" "$B/data"
printf stale > "$B/run/magpie.pid"
printf 'host-mock-key\n' > "$B/data/web.key"; chmod 644 "$B/data/web.key"
_before=$(stat -c '%a:%Y:%Z' "$B/data/web.key")
_out=$(sh "$B/scripts/magpie.service" status 2>&1)
[ "$(cat "$B/run/magpie.pid")" = stale ] && ok "stopped 探测不删除旧 pidfile" || bad "status 删除了 pidfile"
stub_lib 'magpie_main_pid() { echo 424242; }'
_out=$(sh "$B/scripts/magpie.service" status 2>&1)
[ "$_out" = 'running (PID 424242)' ] && [ "$(cat "$B/run/magpie.pid")" = stale ] && ok "running 探测不重写 pidfile" || bad "running status 修改了 pidfile 或报告错误"
[ "$(stat -c '%a:%Y:%Z' "$B/data/web.key")" = "$_before" ] && ok "status 不 chmod 或重写现有密钥" || bad "status 修改了密钥元数据"
rm "$B/run/magpie.pid"
sh "$B/scripts/magpie.service" status >/dev/null 2>&1
[ ! -e "$B/run/magpie.pid" ] && ok "running 探测也不创建缺失的 pidfile" || bad "status 创建了 pidfile"

# 新回归只抽生产函数与 dispatch，加纯宿主替身；所有 kill 都被函数截获。
extract_service() { sed -n "/^$1() /,/^[})]/p" "$SRCDIR/scripts/magpie.service"; }

echo "== 21 精确命令身份：MCP / serve 的 argv 与本体路径都要匹配"
build
mkdir -p "$B/proc/41"
printf 'ignored\000mcp\000vision\000' > "$B/proc/41/cmdline"
ln -s "$B/bin/magpie" "$B/proc/41/exe"
{
  sed -n '/^magpie_pid_command() /,/^[})]/p' "$SRCDIR/scripts/lib.sh" | sed "s#/proc/#$B/proc/#g"
  extract_service service_pid_command
  printf 'BIN="%s/bin/magpie"\nservice_pid_command "$1" "$2"\n' "$B"
} > "$B/identity.sh"
sh "$B/identity.sh" 41 mcp && ok "精确 mcp 子命令通过" || bad "合法 mcp 被拒绝"
printf 'ignored\000update\000mcp\000' > "$B/proc/41/cmdline"
if sh "$B/identity.sh" 41 mcp; then bad "CLI 的 mcp 参数被误认"; else ok "普通 CLI 即使带 mcp 参数也被拒绝"; fi
printf 'ignored\000serve-not\000' > "$B/proc/41/cmdline"
if sh "$B/identity.sh" 41 serve; then bad "serve 前缀被误认"; else ok "serve 必须是完整 argv"; fi
printf 'ignored\000serve\000--web=x\000' > "$B/proc/41/cmdline"
sh "$B/identity.sh" 41 serve && ok "精确 serve 主进程通过" || bad "serve 被拒绝"
rm "$B/proc/41/exe"; ln -s "$B/bin/other" "$B/proc/41/exe"
if sh "$B/identity.sh" 41 serve; then bad "其他本体通过身份检查"; else ok "不同本体路径不能被杀"; fi
rm "$B/proc/41/exe"; ln -s "$B/bin/magpie (deleted)" "$B/proc/41/exe"
sh "$B/identity.sh" 41 serve && ok "升级后持有旧本体 inode 的 serve 仍可停止" || bad "升级后主进程无法停止"
: > "$B/bin/magpie.real"; ln -s "$B/bin/magpie.real" "$B/bin/magpie"
rm "$B/proc/41/exe"; ln -s "$B/bin/magpie.real" "$B/proc/41/exe"
sh "$B/identity.sh" 41 serve && ok "符号链接形式的自定义本体仍能校验身份" || bad "符号链接本体被误拒绝"

echo "== 22 stop 只选择主进程和 MCP；发信号前再次核对身份"
build
mkdir -p "$B/run"
{
  for _fn in running service_pid_matches stop_magpie_pid stop; do extract_service "$_fn"; done
  cat <<'MOCK'
RUN=$1; PIDFILE="$RUN/magpie.pid"; USER_STOPPED="$RUN/.user_stopped"
log() { :; }; cleanup_legacy_dnsmasq() { :; }; sleep() { :; }
with_stop_intent_lock() { : > "$USER_STOPPED"; }
magpie_main_pid() { [ ! -f "$RUN/killed.101" ] && echo 101; }
magpie_all_pids() { echo all >> "$RUN/forbidden"; echo 101 202 303; }
magpie_command_pids() {
  for _mock_pid in 101; do service_pid_command "$_mock_pid" "$1" && echo "$_mock_pid"; done
}
magpie_mcp_pids() {
  for _mock_pid in 202 404 505; do service_pid_command "$_mock_pid" mcp && echo "$_mock_pid"; done
}
service_pid_command() {
  case "$1:$2" in
    101:serve|202:mcp) [ ! -f "$RUN/killed.$1" ] ;;
    404:mcp) return 1 ;; # 选择到候选后已经变成普通 CLI
    505:mcp) [ ! -e "$RUN/term.505" ] ;; # TERM 后 PID 被复用
    *) return 1 ;;
  esac
}
kill() {
  echo "$1 $2" >> "$RUN/signals"
  [ "$1" != -15 ] || : > "$RUN/term.$2"
  [ "$1" != -9 ] || : > "$RUN/killed.$2"
  [ "$1" != -0 ]
}
stop
MOCK
} > "$B/stop-mock.sh"
sh "$B/stop-mock.sh" "$B/run"
[ ! -e "$B/run/forbidden" ] && ! grep -q ' 303$' "$B/run/signals" && ok "stop 不使用 all_pids 且绝不选择普通 CLI" || bad "stop 选择了 CLI / all_pids"
grep -qx -- '-15 101' "$B/run/signals" && grep -qx -- '-9 101' "$B/run/signals" && ok "主进程停止路径仍完整" || bad "主进程未被停止"
grep -qx -- '-15 202' "$B/run/signals" && ok "孤儿 MCP 仍被选择" || bad "遗漏 MCP 孤儿"
if grep -q ' 404$' "$B/run/signals"; then bad "身份变化后仍发 TERM"; else ok "TERM 前重查身份，排除已变化候选"; fi
grep -qx -- '-15 505' "$B/run/signals" && ! grep -qx -- '-9 505' "$B/run/signals" && ok "TERM 后身份变化时绝不补发 KILL" || bad "KILL 前未重查身份"

echo "== 23 toggle 取消 / 启动失败 / 后置退出不能伪报 running"
build
{
  extract_service running
  extract_service start_allowed
  extract_service start
  # 直接抽生产 dispatch 中 toggle 分支，不复制判定算法。
  sed -n '/^  toggle|toggle-if)/,/^    ;;/p' "$SRCDIR/scripts/magpie.service" | sed '1s/  toggle|toggle-if)/toggle_dispatch() {/' | sed '$s/    ;;/}/'
  cat <<'MOCK'
RUN=$1; MODDIR=${RUN%/*}; USER_STOPPED="$RUN/.user_stopped"; PIDFILE="$RUN/magpie.pid"
ADDR_ERROR=""; CONF=unused; BIN="$RUN/no-binary"
log() { :; }; acquire_service_lock() { :; }; sync_status() { :; }
magpie_main_pid() { return 1; }; cleanup_legacy_dnsmasq() { :; }
magpie_mcp_pids() { :; }
with_stop_intent_lock() { has_stop_request && return 2; return 0; }
case "$2" in
  cancel) has_stop_request() { return 0; } ;;
  fail) has_stop_request() { return 1; } ;;
  vanished) start() { return 0; } ;;
esac
toggle_dispatch toggle
MOCK
} > "$B/toggle-mock.sh"
mkdir -p "$B/run"
for _scenario in cancel fail vanished; do
  _out=$(sh "$B/toggle-mock.sh" "$B/run" "$_scenario" 2>&1); _rc=$?
  case "$_scenario:$_rc:$_out" in
    cancel:2:stopped) ok "较新 stop 取消返回 stopped / 2，不伪报 running" ;;
    fail:1:failed) ok "真正启动失败返回 failed / 1" ;;
    vanished:1:failed) ok "start 返回成功但后置已停也不能报 running" ;;
    *) bad "toggle $_scenario 返回错误：$_rc $_out" ;;
  esac
done

echo "== 24 并发首次 start：密钥只能锁内创建且整个启动使用同一份"
build
mkdir -p "$B/run"
# 只模拟 daemon 就绪，不启动任何长期服务，不触碰真实 su / 启停。
printf '#!/bin/sh\nprintf "%%s\\n" "$MAGPIE_WEB_KEY" > "%s/seen.key"\n: > "%s/launched"\n' "$B" "$B" > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"
stub_lib "magpie_main_pid() { [ -f \"$B/launched\" ] && echo 424242; }
magpie_write_ca_bundle() { return 1; }
lan_ip() { return 1; }"
. "$SRCDIR/scripts/lib.sh"
magpie_pick_flock || exit 1
exec 7>>"$B/run/.service.flock"
magpie_flock -n 7 || exit 1
sh "$B/scripts/magpie.service" start 7>&- >"$B/first.log" 2>&1 & _a=$!
sh "$B/scripts/magpie.service" start 7>&- >"$B/second.log" 2>&1 & _b=$!
KIDS="$KIDS $_a $_b"
wait_file "/proc/$_a/fd/9" && wait_file "/proc/$_b/fd/9" || bad "并发 start 没有进入等锁"
[ ! -e "$B/data" ] && ok "等锁期间不提前创建 data / web.key" || bad "密钥在持锁前初始化"
magpie_flock -u 7; exec 7>&-
wait "$_a"; _ar=$?; wait "$_b"; _br=$?
[ "$_ar:$_br" = 0:0 ] && ok "并发首次 start 都完成" || bad "并发 start 失败：$_ar:$_br"
[ "$(wc -c < "$B/data/web.key")" -eq 33 ] && cmp -s "$B/data/web.key" "$B/seen.key" && ok "持久密钥与启动进程收到的密钥完全一致" || bad "并发首次 start 密钥不稳定"
[ "$(stat -c %a "$B/data/web.key")" = 600 ] && ok "并发初始化仍保持密钥 600 权限" || bad "并发密钥权限错误"
if grep -Fq "$(cat "$B/data/web.key")" "$B/first.log" "$B/second.log"; then bad "启动日志泄露密钥"; else ok "并发启动日志不输出密钥"; fi
cp "$B/data/web.key" "$B/stable.key"
rm "$B/launched"  # 模拟 daemon 已退出，下一次必须真正执行 start，而非已运行早退。
sh "$B/scripts/magpie.service" start >"$B/third.log" 2>&1
cmp -s "$B/data/web.key" "$B/stable.key" && cmp -s "$B/seen.key" "$B/stable.key" && ok "后续 start 锁内重读但不更换密钥" || bad "后续 start 更换了密钥"

reap

# 全量控制器 + 生产 lib，只有 /proc 与信号实现是假：不启动任何真实本体。
proc_candidate() {
  _fixture_pid=$1; _fixture_exe=$2; shift 2
  mkdir -p "$B/proc/$_fixture_pid"
  rm -f "$B/proc/$_fixture_pid/exe"
  ln -s "$_fixture_exe" "$B/proc/$_fixture_pid/exe"
  printf '%s\000' "$@" > "$B/proc/$_fixture_pid/cmdline"
}
build_proc_controller() {
  build
  mkdir -p "$B/run" "$B/proc"
  sed "s#/proc/#$B/proc/#g" "$SRCDIR/scripts/lib.sh" > "$B/scripts/lib.sh"
  cat >> "$B/scripts/lib.sh" <<'MOCK'
pidof() { [ "$1" = magpie ] && cat "$magpie_path/candidates"; }
magpie_all_pids() { : > "$RUN/forbidden-all"; echo 90 101 102 201; }
MOCK
  printf '99 90 91 92 101 102 201\n' > "$B/candidates"
  proc_candidate 90 "$B/bin/magpie" magpie update --note 'serve mcp'
  proc_candidate 91 "$B/foreign/magpie" magpie serve
  proc_candidate 92 "$B/bin/magpie" magpie serve-extra
  proc_candidate 101 "$B/bin/magpie" magpie serve
  proc_candidate 102 "$B/bin/magpie" magpie serve --web=x
  proc_candidate 201 "$B/bin/magpie" magpie mcp search
  printf '101\n' > "$B/run/magpie.pid"
  : > "$B/run/signals"
  # 全脚本路径，不抽取或重写 stop/restart 分支，确保真正退出码得到覆盖。
  sed -e "s#^CONF=.*#CONF=$B/cfg#" "$SRCDIR/scripts/magpie.service" | awk -v fixture="$B/control-mocks.sh" '
    /^# 每条 start\/stop 路径/ { print ". \"" fixture "\"" }
    { print }
  ' > "$B/scripts/magpie.service"
  cat > "$B/control-mocks.sh" <<'MOCK'
cleanup_legacy_dnsmasq() { :; }
sync_status() { :; }
sleep() { :; }
# restart 只允许在真实生产 stop 成功后触发此启动哨兵，绝不起真实 daemon。
start() { : > "$RUN/start-sentinel"; return 0; }
service_pid_command() {
  if [ "${MOCK_MODE:-normal}" = before-change ] && [ "$1" = 101 ]; then
    printf 'magpie\000update\000serve\000' > "$magpie_path/proc/101/cmdline"
  fi
  magpie_pid_command "$1" "$2" "$BIN"
}
kill() {
  _signal=$1; _signal_pid=$2
  case "$_signal_pid" in
    101|102|201|301) ;;
    *) : > "$RUN/forbidden-signal"; return 1 ;;
  esac
  if [ "$_signal" = -0 ]; then
    [ -e "$magpie_path/proc/$_signal_pid/cmdline" ]
    return $?
  fi
  printf '%s %s\n' "$_signal" "$_signal_pid" >> "$RUN/signals"
  case "${MOCK_MODE:-normal}:$_signal_pid:$_signal" in
    term-fail:101:-15|kill-fail:101:-9) return 1 ;;
    kill-fail:101:-15|stubborn:101:*|mcp-stubborn:201:*) return 0 ;;
    after-change:101:-15)
      printf 'magpie\000gateway-key\000serve\000' > "$magpie_path/proc/101/cmdline"
      return 0 ;;
    new-serve:102:-15)
      mkdir -p "$magpie_path/proc/301"
      ln -s "$BIN" "$magpie_path/proc/301/exe"
      printf 'magpie\000serve\000' > "$magpie_path/proc/301/cmdline"
      printf '301\n' >> "$magpie_path/candidates"
      ;;
  esac
  rm -rf "$magpie_path/proc/$_signal_pid"
  return 0
}
MOCK
}

echo "== 25 普通 CLI 先于真 serve；多同名主进程都能停止"
build_proc_controller
_out=$(sh "$B/scripts/magpie.service" status 2>&1); _rc=$?
[ "$_rc:$_out" = '0:running (PID 101)' ] && ok "全控制器 status 跳过前面的 CLI / 外来本体 / 伪 serve" || bad "选错主进程：$_rc $_out"
_out=$(sh "$B/scripts/magpie.service" stop 2>&1); _rc=$?
[ "$_rc" = 0 ] && ok "全控制器停止多个真 serve 与 MCP 返回成功" || bad "多进程停止失败：$_rc $_out"
grep -qx -- '-15 101' "$B/run/signals" && grep -qx -- '-15 102' "$B/run/signals" && ok "不只停止第一个真 serve，后面的同名主进程也被处理" || bad "遗漏同名主进程"
grep -qx -- '-15 201' "$B/run/signals" && ok "MCP 孤儿仍被处理" || bad "遗漏 MCP 孤儿"
[ ! -e "$B/run/forbidden-all" ] && [ ! -e "$B/run/forbidden-signal" ] && ok "不使用 all_pids，也不向普通 CLI / 外来本体发信号" || bad "清理边界被破坏"
[ -e "$B/proc/90/cmdline" ] && [ -e "$B/proc/91/cmdline" ] && [ -e "$B/proc/92/cmdline" ] && ok "普通 CLI、其他本体与伪子命令全部原样保留" || bad "误删普通进程夹具"
[ ! -e "$B/run/magpie.pid" ] && [ -f "$B/run/.user_stopped" ] && ok "停止核验成功后才移除 pidfile，保留停止意图" || bad "成功停止元数据不正确"
_out=$(sh "$B/scripts/magpie.service" status 2>&1)
[ "$_out" = stopped ] && ok "停止后只剩伪候选时 status 确定 stopped" || bad "停止后 status 仍误报运行"

for _change in before-change after-change; do
  build_proc_controller
  _out=$(MOCK_MODE="$_change" sh "$B/scripts/magpie.service" stop 2>&1); _rc=$?
  [ "$_rc" = 0 ] && [ -e "$B/proc/101/cmdline" ] && ok "$_change 身份改变后不再把普通 CLI 当成待停止服务" || bad "$_change 身份切换未安全完成：$_rc $_out"
  if [ "$_change" = before-change ]; then
    if grep -q ' 101$' "$B/run/signals"; then bad "TERM 前换身份仍收到信号"; else ok "TERM 前换身份不发任何信号"; fi
  else
    grep -qx -- '-15 101' "$B/run/signals" && ! grep -qx -- '-9 101' "$B/run/signals" && ok "TERM 后换身份不再补发 KILL" || bad "TERM 后身份复用仍收到 KILL"
  fi
  grep -qx -- '-15 102' "$B/run/signals" && [ ! -e "$B/proc/102" ] && ok "$_change 跳过变化候选后继续停止后面的真 serve" || bad "$_change 没有继续清理真 serve"
done

echo "== 26 直接 stop / restart / toggle 必须传播停止失败，失败绝不启动"
for _failure in term-fail kill-fail stubborn mcp-stubborn new-serve; do
  for _action in stop restart toggle; do
    build_proc_controller
    _out=$(MOCK_MODE="$_failure" sh "$B/scripts/magpie.service" "$_action" 2>&1); _rc=$?
    [ "$_rc" -ne 0 ] && ok "$_action / $_failure 返回非零" || bad "$_action / $_failure 错误返回成功：$_out"
    [ ! -e "$B/run/start-sentinel" ] && ok "$_action / $_failure 停止失败绝不继续 start" || bad "$_action / $_failure 仍进入 start"
    [ -f "$B/run/.user_stopped" ] && [ "$(cat "$B/run/magpie.pid" 2>/dev/null)" = 101 ] && ok "$_action / $_failure 保留停止意图和失败 pidfile" || bad "$_action / $_failure 丢失失败状态"
    if [ "$_action" = toggle ]; then
      [ "$(printf '%s\n' "$_out" | tail -1)" = failed ] && ok "toggle / $_failure 输出 failed，不伪报 stopped" || bad "toggle / $_failure 结果文本不正确：$_out"
    fi
  done
done
build_proc_controller
_out=$(sh "$B/scripts/magpie.service" restart 2>&1); _rc=$?
[ "$_rc" = 0 ] && [ -f "$B/run/start-sentinel" ] && [ ! -e "$B/proc/101" ] && [ ! -e "$B/proc/102" ] && [ ! -e "$B/proc/201" ] && ok "成功 restart 仅在全部 serve / MCP 已退出后进入 start" || bad "成功 restart 的顺序或返回值错误：$_rc $_out"
build_proc_controller
rm -rf "$B/proc/101" "$B/proc/102" "$B/proc/201"
_out=$(sh "$B/scripts/magpie.service" stop 2>&1); _rc=$?
[ "$_rc" = 0 ] && [ ! -s "$B/run/signals" ] && [ ! -e "$B/run/magpie.pid" ] && ok "已经停止时直接 stop 幂等成功，不碰仍在运行的普通 CLI" || bad "幂等 stop 不正确：$_rc $_out"

echo "== 27 控制器只返回已核验且仍对应 Web 配置的回环地址"
build_proc_controller
printf '101\n' > "$B/candidates"
printf 'magpie_path="%s"\nMAGPIE_WEB_ADDR="[::1]:3430"\n' "$B" > "$B/cfg"
proc_candidate 101 "$B/bin/magpie" magpie serve '--web=[::1]:3430'
mkdir -p "$B/proc/self/net" "$B/proc/self/ns" "$B/proc/101/ns" "$B/proc/101/fd"
ln -s 'net:[101]' "$B/proc/self/ns/net"
ln -s 'net:[101]' "$B/proc/101/ns/net"
ln -s 'socket:[501]' "$B/proc/101/fd/5"
printf ' sl local_address remote_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n' > "$B/proc/self/net/tcp"
cp "$B/proc/self/net/tcp" "$B/proc/self/net/tcp6"
printf ' 0: 00000000000000000000000001000000:0D66 0:0 0A 0:0 00:0 0 0 0 501\n' >> "$B/proc/self/net/tcp6"
_out=$(sh "$B/scripts/magpie.service" panel-url 2>&1); _rc=$?
[ "$_rc:$_out" = '0:http://[::1]:3430/' ] && ok "真实控制器输出已核验的 IPv6 回环地址" || bad "IPv6 面板地址不正确：$_rc $_out"
proc_candidate 101 "$B/bin/magpie" magpie serve '--web=[::1]:3440'
_out=$(sh "$B/scripts/magpie.service" panel-url 2>&1); _rc=$?
[ "$_rc" -ne 0 ] && [ -z "$_out" ] && ok "当前配置未应用到 Web 时不返回地址" || bad "误把其它端口认作面板：$_out"
proc_candidate 101 "$B/bin/magpie" magpie serve '--web=[::1]:3430'
rm "$B/proc/101/fd/5"
_out=$(sh "$B/scripts/magpie.service" panel-url 2>&1); _rc=$?
[ "$_rc" -ne 0 ] && [ -z "$_out" ] && ok "不能确认 Web socket 归属时拒绝提供地址" || bad "误把未知监听认作面板：$_out"

echo "== 28 doctor 把配置目标与实际监听分开"
_doctor_scope=$(sed -n '/^report_scope() {/,/^}/p' "$SRCDIR/scripts/doctor.sh")
. "$SRCDIR/scripts/lib.sh"
_doctor_result=$(
  eval "$_doctor_scope"
  ok() { echo "ok:$1"; }; warn() { echo "warn:$1"; }; bad() { echo "bad:$1"; }
  report_scope 面板 127.0.0.1:3430 nonlocal
  report_scope 网关 127.0.0.1:3425 unknown
  report_scope 面板 '[::1]:3430' 'local [::1]'
)
if printf '%s\n' "$_doctor_result" | grep -q 'bad:面板.*配置未生效'; then ok "仍有非回环监听时报告不一致"; else bad "doctor 从配置推断局域网已关闭"; fi
if printf '%s\n' "$_doctor_result" | grep -q 'warn:网关.*未知'; then ok "归属未知时不报告安全状态"; else bad "doctor 把未知当作已核验"; fi
if printf '%s\n' "$_doctor_result" | grep -q 'ok:面板.*与配置目标一致'; then ok "IPv6 回环核验成功时报告匹配"; else bad "doctor 未正确处理已核验的 IPv6"; fi

echo "== 29 开机与看门狗只接受当前 boot 的停止意图，结束的 stop 不会被撤销"
build
mkdir -p "$B/run"
_current_boot=11111111-2222-3333-4444-555555555555
_old_boot=11111111-2222-3333-4444-666666666666
stub_lib "magpie_boot_id() { printf '%s\\n' '$_current_boot'; }
magpie_main_pid() { [ -e '$B/launched' ] && printf '424242\\n'; }"
printf '#!/bin/sh\n: > "%s/launched"\n' "$B" > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"
_out=$(sh "$B/scripts/magpie.service" stop 2>&1); _rc=$?
[ "$_rc" -eq 0 ] && grep -qx "boot=$_current_boot" "$B/run/.user_stopped" && ok "stop 写入准确的 boot ID" || bad "停止标记缺失：$_out"
_out=$(sh "$B/scripts/magpie.service" auto-start 2>&1); _rc=$?
[ "$_rc" -eq 2 ] && [ ! -e "$B/launched" ] && ok "stop 已完成、请求文件已清理时也拒绝自动启动" || bad "自动启动覆盖了已完成 stop：$_out"
: > "$B/run/.user_stopped"
_out=$(sh "$B/scripts/magpie.service" auto-start 2>&1); _rc=$?
[ "$_rc" -eq 2 ] && [ ! -e "$B/launched" ] && ok "无法判定旧空标记代次时保守停止" || bad "旧标记被不安全地忽略：$_out"
printf 'boot=%s\n' "$_old_boot" > "$B/run/.user_stopped"
_out=$(sh "$B/scripts/magpie.service" auto-start 2>&1); _rc=$?
[ "$_rc" -eq 0 ] && [ -e "$B/launched" ] && grep -qx "boot=$_old_boot" "$B/run/.user_stopped" && ok "新 boot 可自启且自动路径不删除标记" || bad "处理上一 boot 标记失败：$_out"
: > "$B/run/.user_stopped"
_out=$(sh "$B/scripts/magpie.service" start 2>&1); _rc=$?
[ "$_rc" -eq 0 ] && [ ! -e "$B/run/.user_stopped" ] && ok "显式启动能清除无代次旧标记" || bad "显式启动未覆盖旧标记：$_out"

echo "== 29b 启动准备期间，较新的 stop 发布后不得再派生服务"
build
mkdir -p "$B/run"
stub_lib "magpie_boot_id() { printf '%s\\n' '$_current_boot'; }
magpie_ca_fingerprint() { printf 'fixture\\n'; }
magpie_write_ca_bundle() {
  : > '$B/preparing'
  _prep_left=160
  while [ ! -e '$B/unblock' ] && [ \"\$_prep_left\" -gt 0 ]; do
    sleep 0.03; _prep_left=\$((_prep_left - 1))
  done
  return 1
}"
printf '#!/bin/sh\n: > "%s/launched"\n' "$B" > "$B/bin/magpie"
chmod 755 "$B/bin/magpie"
sh "$B/scripts/magpie.service" auto-start > "$B/auto.log" 2>&1 & _prep_start=$!
KIDS="$KIDS $_prep_start"
wait_file "$B/preparing" || bad "auto-start 未进入准备阶段"
sh "$B/scripts/magpie.service" stop > "$B/stop.log" 2>&1 & _prep_stop=$!
KIDS="$KIDS $_prep_stop"
wait_file "$B/run/.user_stopped" || bad "准备阶段未收到后来的停止意图"
: > "$B/unblock"
wait "$_prep_start"; _prep_rc=$?
wait "$_prep_stop"; _prep_stop_rc=$?
[ "$_prep_rc:$_prep_stop_rc" = 2:0 ] && [ ! -e "$B/launched" ] && ok "启动前复查能取消待派生的服务" || bad "停止前后返回码不符或已派生：$_prep_rc:$_prep_stop_rc"

echo "== 30 条件切换失配时不发信号、不改变停止意图"
build_proc_controller
_out=$(sh "$B/scripts/magpie.service" toggle-if stopped 2>&1); _rc=$?
[ "$_rc:$_out" = '3:stale running' ] && [ ! -s "$B/run/signals" ] && [ ! -e "$B/run/.user_stopped" ] && ok "磁贴以为停服时不停止实际运行的实例" || bad "错误反转 running：$_rc $_out"
_out=$(sh "$B/scripts/magpie.service" toggle-if running 2>&1); _rc=$?
[ "$_rc" -eq 0 ] && [ "$(printf '%s\n' "$_out" | tail -1)" = stopped ] && [ -f "$B/run/.user_stopped" ] && ok "预期运行与实际一致时执行真正 stop" || bad "有效的条件停止失败：$_out"
_prev=$(cat "$B/run/.user_stopped")
_out=$(sh "$B/scripts/magpie.service" toggle-if running 2>&1); _rc=$?
[ "$_rc:$_out" = '3:stale stopped' ] && [ ! -e "$B/run/start-sentinel" ] && [ "$(cat "$B/run/.user_stopped")" = "$_prev" ] && ok "磁贴以为运行时不重新拉起已停止实例" || bad "错误反转 stopped：$_rc $_out"

reap

echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
