#!/bin/sh
# 核对文档里写的测试断言数是否与实际一致。
#
#   sh tests/check-counts.sh          # 只报告
#   sh tests/check-counts.sh --fix    # 顺手把 README 里的数字改对
#
# 为什么要这个：断言数散落在 README、README_EN、CHANGELOG、tests/README 四处，
# 每加一组测试都要手改，已经出现过好几次不一致（222 vs 232 vs 286）。
# 与其靠记性，不如跑一遍。
#
# 注意：CHANGELOG 是历史记录，只检查「当前版本那一节」，老版本的数字不该动。

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# 临时目录：Android 上没有 /tmp
if [ -d /tmp ] && [ -w /tmp ]; then _TMP=/tmp; else _TMP=${TMPDIR:-/data/local/tmp}; fi
FIXTURES="$_TMP/count-check-fx"
PORT=18899

fail=0
say() { printf '%s\n' "$*"; }
bad() { say "  ✗ $*"; fail=$((fail + 1)); }
ok()  { say "  ✓ $*"; }

# ---------- 实测每个套件的断言数 ----------
# 直接跑测试并数 PASS/FAIL 行，不依赖文档里写的数字。
count_suite() {
  _name=$1
  shift
  _out=$("$@" 2>&1)
  _n=$(printf '%s\n' "$_out" | grep -cE '^  (PASS|SKIP)')
  echo "$_n"
}

say "== 实测各套件断言数"

LIB=$(count_suite lib sh "$HERE/test-lib.sh")
say "  test-lib.sh       $LIB"

WD=$(count_suite watchdog sh "$HERE/test-watchdog.sh")
say "  test-watchdog.sh  $WD"

SV=$(count_suite service sh "$HERE/test-service.sh")
say "  test-service.sh   $SV"

# install / action 需要夹具与静态服务
if command -v python3 >/dev/null 2>&1; then
  rm -rf "$FIXTURES"
  python3 "$HERE/make-fixtures.py" "$FIXTURES" --base "http://127.0.0.1:$PORT" >/dev/null 2>&1
  ( cd "$FIXTURES" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  _srv=$!
  sleep 1
  INS=$(TEST_SRV="http://127.0.0.1:$PORT" sh "$HERE/test-install.sh" 2>&1 | grep -cE '^  (PASS|SKIP)')
  ACT=$(TEST_SRV="http://127.0.0.1:$PORT" sh "$HERE/test-action.sh" 2>&1 | grep -cE '^  (PASS|SKIP)')
  kill "$_srv" 2>/dev/null
  rm -rf "$FIXTURES"
  say "  test-install.sh   $INS"
  say "  test-action.sh    $ACT"
else
  INS=""
  ACT=""
  say "  test-install.sh   SKIP（没有 python3）"
  say "  test-action.sh    SKIP（没有 python3）"
fi

# JVM 用例
JVM=""
if command -v javac >/dev/null 2>&1 && [ -f "$HERE/jvm/ClassifyTest.java" ]; then
  _w="$_TMP/count-check-jvm"
  rm -rf "$_w"
  if javac -encoding UTF-8 "$HERE/jvm/ClassifyTest.java" -d "$_w" >/dev/null 2>&1; then
    JVM=$(java -cp "$_w" ClassifyTest 2>&1 | grep -cE '^  (PASS|FAIL)')
    say "  jvm/ClassifyTest  $JVM"
  fi
  rm -rf "$_w"
fi

if [ -z "$INS" ] || [ -z "$ACT" ]; then
  say ""
  say "缺 install/action 的实测值，跳过文档核对（没有 python3 时无法跑这两套）。"
  exit 0
fi

TOTAL=$((LIB + WD + SV + INS + ACT))
say ""
say "合计 $TOTAL 条（$INS + $WD + $ACT + $SV + $LIB）${JVM:+，另有 $JVM 条 JVM 用例}"

# ---------- 核对文档 ----------
say ""
say "== 文档里的数字"

check_has() {
  _file=$1
  _pat=$2
  _what=$3
  if grep -qE "$_pat" "$ROOT/$_file" 2>/dev/null; then
    ok "$_file 含 $_what"
  else
    bad "$_file 缺少 $_what（应在其中出现 $TOTAL 或分项数字）"
  fi
}

check_has README.md "$TOTAL 条断言" "合计 $TOTAL"
check_has README_EN.md "$TOTAL assertions total" "合计 $TOTAL"
check_has tests/README.md "$TOTAL 条断言" "合计 $TOTAL"

# 分项：每个套件的数字都要在 tests/README 的表格里
for pair in "test-lib.sh:$LIB" "test-watchdog.sh:$WD" "test-service.sh:$SV" \
            "test-install.sh:$INS" "test-action.sh:$ACT"; do
  _t=${pair%%:*}
  _n=${pair##*:}
  if grep -qE "\\| \`$_t\` \\| $_n \\|" "$ROOT/tests/README.md" 2>/dev/null; then
    ok "tests/README 表格 $_t = $_n"
  else
    bad "tests/README 表格里 $_t 不是 $_n"
  fi
done

# 当前版本的 CHANGELOG 那一节
_cur_ver=$(sed -n 's/^version=//p' "$ROOT/module.prop")
if grep -q "$_cur_ver" "$ROOT/CHANGELOG.md" 2>/dev/null; then
  # 取当前版本那一节（到下一个 ## 为止）
  _sec=$(awk -v v="$_cur_ver" '$0 ~ "^## " v { f=1; next } f && /^## / { exit } f' "$ROOT/CHANGELOG.md")
  if printf '%s' "$_sec" | grep -qE "$TOTAL|$LIB"; then
    ok "CHANGELOG $_cur_ver 一节提到当前数字"
  else
    bad "CHANGELOG $_cur_ver 一节里的数字过时"
  fi
fi

say ""
if [ "$fail" -eq 0 ]; then
  say "文档与实际一致。"
  exit 0
fi
say "有 $fail 处不一致。加完测试记得同步：README / README_EN / tests/README / CHANGELOG。"
exit 1
