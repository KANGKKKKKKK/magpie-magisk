#!/bin/sh
# action.sh 的测试：菜单分支、命令行子命令、以及「读不到按键」时的老式一键启停退路。
# 全程不碰真实服务（进程判定与 service 都换成桩），也不读真实配置。
#
# 用法: TEST_SRV=http://127.0.0.1:8899 sh tests/test-action.sh
#
# 隔离要点（否则测的是真实模块）：
#   1. action.sh 与 install.sh 的 CONF 都要改指沙箱配置
#   2. magpie_running 是桩 —— 真实 magpie 可能就在跑，不可能凭空消失
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/.."
SRV=${TEST_SRV:-}
# 临时目录：Android 上没有 /tmp，退到 TMPDIR 或 /data/local/tmp
if [ -d /tmp ] && [ -w /tmp ]; then
  _TMPBASE=/tmp
else
  _TMPBASE=${TMPDIR:-/data/local/tmp}
fi
B=${TEST_BASE:-$_TMPBASE/magpie-action-test}
PASS=0; FAIL=0

[ -n "$SRV" ] || { echo "请设置 TEST_SRV，例如 TEST_SRV=http://127.0.0.1:8899"; exit 2; }
# 清单里的下载地址是生成时写死的：换了端口就必须用 --base 重新生成，
# 否则会出现一堆「下载失败」的假失败。
echo "提示：夹具要与地址对应：python3 tests/make-fixtures.py <dir> --base $SRV"

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# 一个能应答 --version 的假本体（shebang 按平台选）
make_fake_binary() {
  _sh=/bin/sh
  [ -x /system/bin/sh ] && _sh=/system/bin/sh
  printf '#!%s\ncase "$1" in\n  --version) echo "magpie 9.9.9" ;;\n  *) exit 0 ;;\nesac\n' "$_sh" > "$B/bin/magpie"
  chmod 755 "$B/bin/magpie"
}

# $1 = ready | missing ；$2 = running | stopped ；$3 = lan | local
build() {
  rm -rf "$B"; mkdir -p "$B/scripts" "$B/bin"
  # 整行替换，不匹配具体写法：配置行以后怎么改都不会让沙箱失联
  sed -e "s#^CONF=.*#CONF=$B/cfg#" \
      -e "s#^SERVICE=.*#SERVICE=\"$B/scripts/magpie.service\"#" \
      "$SRC/action.sh" > "$B/action.sh"
  # 整行替换，不匹配具体写法：配置行以后怎么改都不会让沙箱失联
  sed -e "s#^CONF=.*#CONF=$B/cfg#" \
      "$SRC/scripts/install.sh" > "$B/scripts/install.sh"
  printf 'magpie_path="%s"\n' "$B" > "$B/cfg"
  case "${3:-local}" in
    lan)   printf 'MAGPIE_ADDR="0.0.0.0:3425"\nMAGPIE_WEB_ADDR="0.0.0.0:3430"\n' >> "$B/cfg" ;;
    *)     printf 'MAGPIE_ADDR="127.0.0.1:3425"\nMAGPIE_WEB_ADDR="127.0.0.1:3430"\n' >> "$B/cfg" ;;
  esac
  cp "$SRC/scripts/lib.sh" "$B/scripts/lib.sh"
  # 只在临时副本放行本沙箱，不给生产代码添加路径绕过环境变量。
  printf '\nmagpie_path_installable() { case "$1" in "%s"|"%s"/*) return 0 ;; esac; return 1; }\n' \
    "$B" "$B" >> "$B/scripts/lib.sh"

  # 进程判定改桩：真实 magpie 还在跑，别让它影响结果
  if [ "$2" = "running" ]; then
    printf '\nmagpie_main_pid() { echo 1; }\nmagpie_running() { return 0; }\nmagpie_all_pids() { echo 1; }\n' >> "$B/scripts/lib.sh"
  else
    printf '\nmagpie_main_pid() { return 1; }\nmagpie_running() { return 1; }\nmagpie_all_pids() { :; }\n' >> "$B/scripts/lib.sh"
  fi

  printf '#!/bin/sh\nexit 0\n' > "$B/scripts/status.sh"
  printf '#!/bin/sh\necho "STUB service $*" >> %s/calls.log\nexit 0\n' "$B" > "$B/scripts/magpie.service"

  [ "$1" = "ready" ] && make_fake_binary
  chmod 755 "$B"/*.sh "$B"/scripts/*.sh
  : > "$B/calls.log"
  # 假 input：记下有没有被要求按返回键，绝不真按键
  printf '#!/bin/sh\necho "$*" >> %s/input.log\n' "$B" > "$B/input"
  chmod 755 "$B/input"
  : > "$B/input.log"
}

# 跑 action.sh：PATH 前置沙箱目录，让 input 用假的
run() { PATH="$B:$PATH" sh "$B/action.sh" "$@"; }

export MAGPIE_MANIFEST_URL="$SRV/manifest.json"
export MAGPIE_CONFIRM_WINDOW=600
# 这条用例会调 install.sh plan；CI 在 x86_64 上会被架构闸门挡掉
export MAGPIE_ALLOW_ANY_ARCH=1

echo "== 1 本体缺失：应进安装流程，不调用启停"
build missing stopped
out=$(run 2>&1)
has "$out" "还没装 Magpie 本体" && ok "提示本体未安装" || bad "没有进入安装分支"
has "$out" "确认后才会下载" && ok "给出方案与确认方式" || bad "没有给出方案"
n=$(grep -c "STUB service" "$B/calls.log" 2>/dev/null)
[ "$n" = "0" ] && ok "没有调用启停" || bad "调用了 service $n 次"
[ -f "$B/bin/magpie" ] && bad "不该下载却落盘" || ok "没有提前下载"

echo
echo "== 2 本体损坏：同样进安装流程"
build missing stopped
printf 'not a binary\n' > "$B/bin/magpie"; chmod 755 "$B/bin/magpie"
out=$(run 2>&1)
has "$out" "本体在，但跑不起来" && ok "识别为损坏并进安装流程" || bad "未识别：$out"
n=$(grep -c "STUB service" "$B/calls.log" 2>/dev/null)
[ "$n" = "0" ] && ok "没有调用启停" || bad "调用了 service $n 次"

echo
echo "== 3 无音量键 + 服务在跑：退回老式一键启停（先报信息再停止）"
build ready running
out=$(run 2>&1)
has "$out" "读不到音量键" && ok "说明退路原因" || bad "没有说明退路：$out"
has "$out" "网关" && ok "先打印接入信息" || bad "没打印接入信息"
has "$out" "停止中" && ok "进入停止" || bad "没进入停止"
# 进程判定是桩（恒为「在跑」），停止循环必然超时 —— 这时如实报失败才对
has "$out" "没能停掉" && ok "恒在跑时如实报停止失败" || bad "失败没被识别：$out"
n=$(grep -c "STUB service stop" "$B/calls.log" 2>/dev/null)
[ "$n" -ge 1 ] && ok "调用了 service stop（桩）" || bad "没有调用 stop"

echo
echo "== 4 无音量键 + 服务没跑：退回老式一键启停（启动并开面板）"
build ready stopped
out=$(run 2>&1)
has "$out" "启动中" && ok "进入启动" || bad "没进入启动：$out"
n=$(grep -c "STUB service start" "$B/calls.log" 2>/dev/null)
[ "$n" -ge 1 ] && ok "调用了 service start（桩）" || bad "没有调用 start"
has "$out" "没能启动" && ok "桩没拉起进程，如实报失败" || bad "失败没被识别：$out"
has "$out" "面板" && ok "顺带给出面板地址" || bad "没给面板地址"

echo
echo "== 5 status 子命令：列出本机地址与提示"
build ready running
out=$(run status 2>&1)
has "$out" "http://127.0.0.1:3425/v1" && ok "给出网关地址" || bad "缺网关地址：$out"
has "$out" "面板" && ok "给面板地址" || bad "缺面板地址"
has "$out" "局域网未开放" && ok "仅本机时说明局域网状态" || bad "缺局域网说明"

echo
echo "== 6 status 子命令（局域网模式）：给出局域网地址"
build ready running lan
out=$(PATH="$B:$PATH" sh -c "MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null; lan_ip() { echo 10.1.2.3; }; print_endpoints" 2>&1)
has "$out" "10.1.2.3:3425" && ok "给出局域网网关地址" || bad "缺局域网地址：$out"
has "$out" "平板" && ok "给出别的设备该怎么填" || bad "缺平板行"

echo
echo "== 7 gateway 子命令：当前网关 + 配置里的两行"
build ready running lan
out=$(run gateway 2>&1)
has "$out" "当前网关" && ok "报当前网关" || bad "没报网关：$out"
has "$out" "MAGPIE_ADDR" && ok "列出配置行" || bad "没列配置"

echo
echo "== 8 未知子命令：给用法并以非零退出"
build ready running
out=$(run nope 2>&1); rc=$?
[ "$rc" != "0" ] && ok "退出码非零（$rc）" || bad "退出码是 0"
has "$out" "status" && ok "列出可用子命令" || bad "没列子命令"
n=$(grep -c "STUB service" "$B/calls.log" 2>/dev/null)
[ "$n" = "0" ] && ok "没有误调启停" || bad "误调了 service $n 次"

echo
echo "== 9 音量键解析：只认按下，松开不重复触发"
build ready running
printf '' > "$B/keys.log"
res=$(PATH="$B:$PATH" sh -c "
  MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null
  KEYLOG='$B/keys.log'; KEYN=0
  line() { printf '/dev/input/event0: EV_KEY       %-20s %-20s\n' \"\$1\" \"\$2\" >> \"\$KEYLOG\"; }
  line KEY_VOLUMEDOWN DOWN; read_key 2; echo \"down=\$KEYLAST\"
  line KEY_VOLUMEDOWN UP;   read_key 1; echo \"up=\$KEYLAST\"
  line KEY_VOLUMEUP DOWN;   read_key 2; echo \"upkey=\$KEYLAST\"
" 2>&1)
has "$res" "down=down" && ok "音量下 → down" || bad "没认出按下：$res"
has "$res" "up=timeout" && ok "松开不触发（KEY_VOLUMEDOWN 含 DOWN 不上当）" || bad "松开被误判：$res"
has "$res" "upkey=up" && ok "音量上 → up" || bad "没认出音量上：$res"

echo
echo "== 10 界面模式：终端重画带光标归位，非终端一个控制符都不发"
build ready running
tty_out=$(MAGPIE_ACTION_TTY=1 PATH="$B:$PATH" sh -c "MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null; draw_menu; draw_menu" 2>&1)
nt_out=$(MAGPIE_ACTION_NOTTY=1 PATH="$B:$PATH" sh -c "MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null; draw_menu; SEL=4; show_sel" 2>&1)
tty_esc=$(printf '%s' "$tty_out" | tr -cd '\033' | wc -c | tr -d ' ')
nt_esc=$(printf '%s' "$nt_out" | tr -cd '\033' | wc -c | tr -d ' ')
[ "$tty_esc" -ge 2 ] && ok "终端模式发了光标控制符（$tty_esc 个）" || bad "终端模式没有重画"
[ "$nt_esc" = "0" ] && ok "非终端模式没有控制符" || bad "非终端混进了 $nt_esc 个控制符"
has "$nt_out" "→ 4" && ok "非终端只追加一行选中项" || bad "没追加选中项：$nt_out"
tty_heads=$(printf '%s' "$tty_out" | grep -c "Magpie  ─")
nt_heads=$(printf '%s' "$nt_out" | grep -c "Magpie  ─")
[ "$tty_heads" = "2" ] && ok "终端模式画了两次（原地重画）" || bad "终端重画次数 $tty_heads"
[ "$nt_heads" = "1" ] && ok "非终端只画一次菜单" || bad "非终端画了 $nt_heads 次"

echo
echo "== 11 收尾：不在管理器里跑时，不按返回键"
build ready running
: > "$B/input.log"
out=$(PATH="$B:$PATH" sh -c "MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null; close_console; echo rc=\$?" 2>&1)
n=$(grep -c "4" "$B/input.log" 2>/dev/null)
[ "$n" = "0" ] && ok "没有要求按返回键" || bad "误按了返回键 $n 次"
has "$out" "rc=0" && ok "正常返回" || bad "返回值异常：$out"

echo
echo "== 12 收尾：判定在管理器里时，按一次返回键"
build ready running
: > "$B/input.log"
out=$(PATH="$B:$PATH" sh -c "MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null; inside_manager() { return 0; }; close_console; echo rc=\$?" 2>&1)
n=$(grep -c "keyevent 4" "$B/input.log" 2>/dev/null)
[ "$n" = "1" ] && ok "在管理器里跑时按了一次返回键" || bad "返回键调用 $n 次"
has "$out" "rc=0" && ok "正常返回" || bad "返回值异常：$out"

echo
echo "== 13 收尾：前台是管理器（不在它的子进程里）也按一次"
build ready running
: > "$B/input.log"
out=$(PATH="$B:$PATH" sh -c "MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null; inside_manager() { return 1; }; fg_pkg() { echo com.topjohnwu.magisk; }; close_console; echo rc=\$?" 2>&1)
n=$(grep -c "keyevent 4" "$B/input.log" 2>/dev/null)
[ "$n" = "1" ] && ok "前台是管理器时按了一次返回键" || bad "返回键调用 $n 次"

echo
echo "== 14 包名清单：认管理器，不认别的"
build ready running
out=$(PATH="$B:$PATH" sh -c "MAGPIE_ACTION_LIB=1 . '$B/action.sh' 2>/dev/null; is_mgr_pkg com.topjohnwu.magisk && echo M1; is_mgr_pkg me.weishu.kernelsu && echo M2; is_mgr_pkg com.dergoogler.mmrl && echo M3; is_mgr_pkg com.android.chrome || echo N1" 2>&1)
has "$out" "M1" && has "$out" "M2" && has "$out" "M3" && ok "Magisk / KernelSU / MMRL 都算" || bad "漏了管理器：$out"
has "$out" "N1" && ok "普通 App 不算" || bad "误判成管理器：$out"

echo
echo "== 15 白名单外路径：status 可用，启停被就绪检查拦下"
build ready stopped
# build 给沙箱副本加了放行；再定义拒绝版本，模拟配置指向白名单外的旧目录。
printf '\nmagpie_path_installable() { return 1; }\n' >> "$B/scripts/lib.sh"
out=$(run status 2>&1)
has "$out" "http://127.0.0.1:3425/v1" && ok "status 仍给出接入信息" || bad "status 被误拦：$out"
out=$(run start 2>&1); rc=$?
has "$out" "本体还没装好" && ok "start 被就绪检查拦下" || bad "start 没有被拦：$out"
[ "$rc" -ne 0 ] && ok "start 返回非零" || bad "start 返回 0"

rm -rf "$B"
echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
