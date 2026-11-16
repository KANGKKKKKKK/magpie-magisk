#!/bin/sh
# 看门狗决定逻辑测试
# 把 service.sh 里看门狗循环体抽出来，前面接一段沙箱前言，前台同步跑。
#
# 用法: sh tests/test-watchdog.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../service.sh"
WD=${TEST_BASE:-/tmp/magpie-watchdog-test}
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

build() {
  rounds="$1"
  rm -rf "$WD"; mkdir -p "$WD/run" "$WD/scripts"
  cp "$HERE/../scripts/lib.sh" "$WD/scripts/lib.sh"

  {
    echo "WD=$WD"
    echo "MODDIR=$WD"
    echo "MP=$WD"
    echo "WATCH_LOG=$WD/run/watchdog.log"
    echo '. "$MODDIR/scripts/lib.sh"'
    echo "wlog() { echo \"\$(date +'%H:%M:%S') \$1\" >> \"$WD/run/watchdog.log\" 2>/dev/null; }"
    echo '_last_lan=""'
    echo "_wait=0"
    echo "_miss_logged=0"
    echo "_fail=0"
    echo "_n=0"
    echo "while [ \"\$_n\" -lt $rounds ]; do"
    echo "  _n=\$((_n+1))"
  } > "$WD/loop.sh"

  # 循环体：sleep 在循环开头，所以从它之后取，到 done 之前结束
  awk '
    /^    sleep "\$_wait"$/ { inside = 1; next }
    /^  done$/ { exit }
    inside { print }
  ' "$SRC" >> "$WD/loop.sh"
  echo "done" >> "$WD/loop.sh"
  chmod 755 "$WD/loop.sh"

  printf '#!/bin/sh\nexit 0\n' > "$WD/scripts/status.sh";  chmod 755 "$WD/scripts/status.sh"
  printf '#!/bin/sh\nexit 1\n' > "$WD/scripts/magpie.service"; chmod 755 "$WD/scripts/magpie.service"
}

fake_running() { printf '\nmagpie_running() { %s; }\n' "$1" >> "$WD/scripts/lib.sh"; }
put_elf()      { mkdir -p "$WD/bin"; printf '\177ELF\002\001\001' > "$WD/bin/magpie"; chmod 755 "$WD/bin/magpie"; }
logtext()      { cat "$WD/run/watchdog.log" 2>/dev/null; }

echo "== 0 抽出来的循环脚本语法自检"
build 3
fake_running 'return 1'
sh -n "$WD/loop.sh" && ok "语法通过" || bad "语法错误"

echo
echo "== 1 本体缺失：只记一次，且不尝试拉起"
build 5
fake_running 'return 1'
sh "$WD/loop.sh" >/dev/null 2>&1
n=$(logtext | grep -c "本体未安装或不可用")
[ "$n" = "1" ] && ok "只记 1 次（跑了 5 轮）" || bad "记了 $n 次"
n=$(logtext | grep -c "重新拉起")
[ "$n" = "0" ] && ok "没有尝试拉起" || bad "仍尝试拉起 $n 次"

echo
echo "== 2 本体就位但拉起失败：计数累加并退避"
build 4
put_elf
fake_running 'return 1'
sh "$WD/loop.sh" >/dev/null 2>&1
logtext | sed 's/^/     /'
n=$(logtext | grep -c "拉起失败")
[ "$n" -ge 2 ] && ok "记录了失败（$n 次）" || bad "没有记录失败"
seq=$(logtext | sed -n 's/.*，\([0-9]*\) 秒后再试.*/\1/p' | tr '\n' ' ')
echo "     退避序列: $seq"
case "$seq" in "20 40 80 "*) ok "退避 20/40/80" ;; *) bad "退避不对：$seq" ;; esac

echo
echo "== 3 本体就位且拉起成功：不报失败"
build 3
put_elf
printf '#!/bin/sh\nexit 0\n' > "$WD/scripts/magpie.service"; chmod 755 "$WD/scripts/magpie.service"
fake_running 'return 1'
sh "$WD/loop.sh" >/dev/null 2>&1
n=$(logtext | grep -c "拉起失败")
[ "$n" = "0" ] && ok "成功路径没有失败记录" || bad "误报失败 $n 次"
n=$(logtext | grep -c "重新拉起")
[ "$n" -ge 1 ] && ok "确实尝试过拉起（$n 次）" || bad "没有尝试拉起"

echo
echo "== 4 .user_stopped 存在时不拉起"
build 3
put_elf
: > "$WD/run/.user_stopped"
fake_running 'return 1'
sh "$WD/loop.sh" >/dev/null 2>&1
n=$(logtext | grep -c "重新拉起")
[ "$n" = "0" ] && ok "尊重停止标记" || bad "无视标记，拉起 $n 次"

rm -rf "$WD"
echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
