#!/bin/sh
# action.sh 的分支测试：确认它在「本体没装 / 损坏 / 就绪」三种状态下走对分支，
# 且不碰真实服务（进程判定与 service 都换成桩）。
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
B=${TEST_BASE:-/tmp/magpie-action-test}
PASS=0; FAIL=0

[ -n "$SRV" ] || { echo "请设置 TEST_SRV，例如 TEST_SRV=http://127.0.0.1:8899"; exit 2; }

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# 一个能应答 --version 的假本体（shebang 按平台选）
make_fake_binary() {
  _sh=/bin/sh
  [ -x /system/bin/sh ] && _sh=/system/bin/sh
  printf '#!%s\ncase "$1" in\n  --version) echo "magpie 9.9.9" ;;\n  *) exit 0 ;;\nesac\n' "$_sh" > "$B/bin/magpie"
  chmod 755 "$B/bin/magpie"
}

# $1 = ready | missing ；$2 = running | stopped
build() {
  rm -rf "$B"; mkdir -p "$B/scripts" "$B/bin"
  sed -e "s#^CONF=/data/adb/magpie/scripts/magpie.config#CONF=$B/cfg#" \
      "$SRC/action.sh" > "$B/action.sh"
  sed -e "s#^CONF=/data/adb/magpie/scripts/magpie.config#CONF=$B/cfg#" \
      "$SRC/scripts/install.sh" > "$B/scripts/install.sh"
  printf 'magpie_path="%s"\n' "$B" > "$B/cfg"
  cp "$SRC/scripts/lib.sh" "$B/scripts/lib.sh"

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
}

export MAGPIE_MANIFEST_URL="$SRV/manifest.json"
export MAGPIE_CONFIRM_WINDOW=600

echo "== 1 本体缺失：应进安装流程，不调用启停"
build missing stopped
out=$(sh "$B/action.sh" 2>&1)
case "$out" in *"尚未安装"*) ok "提示本体未安装" ;; *) bad "没有进入安装分支" ;; esac
case "$out" in *"确认后才会下载"*) ok "给出方案与确认方式" ;; *) bad "没有给出方案" ;; esac
n=$(grep -c "STUB service" "$B/calls.log" 2>/dev/null)
[ "$n" = "0" ] && ok "没有调用启停" || bad "调用了 service $n 次"
[ -f "$B/bin/magpie" ] && bad "不该下载却落盘" || ok "没有提前下载"

echo
echo "== 2 本体损坏：同样进安装流程"
build missing stopped
printf 'not a binary\n' > "$B/bin/magpie"; chmod 755 "$B/bin/magpie"
out=$(sh "$B/action.sh" 2>&1)
case "$out" in *"存在但跑不起来"*) ok "识别为损坏并进安装流程" ;; *) bad "未识别：$out" ;; esac
n=$(grep -c "STUB service" "$B/calls.log" 2>/dev/null)
[ "$n" = "0" ] && ok "没有调用启停" || bad "调用了 service $n 次"

echo
echo "== 3 本体就绪且服务在跑：走停止分支"
build ready running
out=$(sh "$B/action.sh" 2>&1)
case "$out" in *"正在运行"*) ok "识别为运行中" ;; *) bad "没识别：$out" ;; esac
case "$out" in *"停止 magpie"*) ok "进入了停止分支" ;; *) bad "没进入停止分支" ;; esac
# 进程判定是桩（恒为「在跑」），停止循环必然超时 —— 这时如实报失败才对
case "$out" in *"停止失败"*) ok "恒在跑时如实报停止失败" ;; *) bad "失败没被识别：$out" ;; esac
n=$(grep -c "STUB service stop" "$B/calls.log" 2>/dev/null)
[ "$n" -ge 1 ] && ok "调用了 service stop（桩）" || bad "没有调用 stop"

echo
echo "== 4 本体就绪但服务没跑：走启动分支"
build ready stopped
out=$(sh "$B/action.sh" 2>&1)
case "$out" in *"启动 magpie"*) ok "进入启动分支" ;; *) bad "没进入启动：$out" ;; esac
n=$(grep -c "STUB service start" "$B/calls.log" 2>/dev/null)
[ "$n" -ge 1 ] && ok "调用了 service start（桩）" || bad "没有调用 start"
case "$out" in *"启动失败"*) ok "桩没拉起进程，如实报失败" ;; *) bad "失败没被识别：$out" ;; esac

rm -rf "$B"
echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
