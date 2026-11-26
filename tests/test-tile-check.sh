#!/bin/sh
# tile-check.sh 的纯宿主替身回归：固定系统路径重写到临时夹具，绝不调用真 su / 启停。
# 用法: sh tests/test-tile-check.sh；无需手机、root 方案、sqlite 或其他外部脚本。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRCDIR=${TEST_SRC_DIR:-$HERE/..}
B=$(mktemp -d "${TMPDIR:-/tmp}/magpie-tile-check.XXXXXX") || exit 1
trap 'rm -rf "$B"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
HOST_SH=$(command -v sh); HOST_CAT=$(command -v cat); HOST_LS=$(command -v ls)
export HOST_SH HOST_CAT HOST_LS
FIX="$B/fixture"; export FIX
mkdir -p "$B/bin" "$FIX"
sed -e "s#/data/adb/modules#$FIX/modules#g" \
    -e "s#/sys/fs/cgroup#$FIX/cgroup#g" \
    -e "s#/proc#$FIX/proc#g" \
    -e "s#/data/system#$FIX/system#g" \
    "$SRCDIR/scripts/tile-check.sh" > "$B/check.sh"

cat > "$B/bin/pm" <<'MOCK'
#!/bin/sh
"$HOST_CAT" "$FIX/packages"
exit "$PM_RC"
MOCK
cat > "$B/bin/settings" <<'MOCK'
#!/bin/sh
case "$3" in
  sysui_qs_tiles) "$HOST_CAT" "$FIX/qs"; exit "$QS_RC" ;;
  cached_apps_freezer) echo disabled; exit 0 ;;
  *) exit 1 ;;
esac
MOCK
cat > "$B/bin/dumpsys" <<'MOCK'
#!/bin/sh
"$HOST_CAT" "$FIX/dump"
exit "$DUMP_RC"
MOCK
cat > "$B/magisk.mock" <<'MOCK'
#!/bin/sh
"$HOST_CAT" "$FIX/sql"
exit "$SQL_RC"
MOCK
cat > "$B/bin/service" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$B/bin/ls" <<'MOCK'
#!/bin/sh
[ "$LS_RC" = 0 ] || exit "$LS_RC"
exec "$HOST_LS" "$@"
MOCK
cat > "$B/bin/sh" <<'MOCK'
#!/bin/sh
[ "$#" = 2 ] && [ "$1" = "$FIX/modules/magpie/scripts/magpie.service" ] && [ "$2" = status ] || {
  : > "$FIX/unexpected-control"; exit 97;
}
exec "$HOST_SH" "$@"
MOCK
for _cmd in su kill; do
  cat > "$B/bin/$_cmd" <<'MOCK'
#!/bin/sh
: > "$FIX/unexpected-control"
exit 98
MOCK
done
chmod 755 "$B/bin/"* "$B/magisk.mock"
# 子进程只看白名单宿主工具与替身，不允许 fallback 到手机上的真实命令。
for _cmd in cat sed grep head tr; do
  ln -s "$(command -v "$_cmd")" "$B/bin/$_cmd"
done
MOCK_PATH="$B/bin"

build() {
  rm -rf "$FIX"; mkdir -p "$FIX/modules/magpie/scripts" "$FIX/proc/11" \
    "$FIX/cgroup/uid_10330/pid_11" "$FIX/system"
  PM_RC=0; QS_RC=0; DUMP_RC=0; SQL_RC=0; LS_RC=0; SVC_RC=0
  export PM_RC QS_RC DUMP_RC SQL_RC LS_RC SVC_RC
  cp "$B/magisk.mock" "$B/bin/magisk"
  printf 'package:com.ruin.magpie.tile versionCode:88 uid:10330\n' > "$FIX/packages"
  printf 'wifi,custom(com.ruin.magpie.tile/.MagpieTileService),bt\n' > "$FIX/qs"
  printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]\n' > "$FIX/dump"
  printf 'policy=2\n' > "$FIX/sql"
  printf 'running (PID 41)\n' > "$FIX/svc"
  printf '0::/uid_10330/pid_11\n' > "$FIX/proc/11/cgroup"
  printf '0\n' > "$FIX/cgroup/uid_10330/pid_11/cgroup.freeze"
  cat > "$FIX/modules/magpie/scripts/magpie.service" <<'MOCK'
#!/bin/sh
"$HOST_CAT" "$FIX/svc"
exit "$SVC_RC"
MOCK
}
get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
expect() {
  if [ "$(get "$1")" = "$2" ]; then ok "$3"; else bad "$3（$1 应为 $2）"; fi
}
run_check() {
  OUT=$(PATH="$MOCK_PATH" "$HOST_SH" "$B/check.sh" 2>"$B/check.err"); RC=$?
  if [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | tail -1)" = done=1 ] && [ "$(get 'done')" = 1 ]; then
    ok "协议正常结束且最后只有一条 done=1"
  else
    bad "协议未完整结束（rc=$RC）"
  fi
}

echo "== tile-check 正常取数与 doctor 既有字段兼容"
build; run_check
expect mod 1 "模块已安装"
expect svc running "服务正常运行"
expect installed 1 "精确包名已安装"
expect uid 10330 "UID 字段兼容"
expect vcode 88 "版本字段兼容"
expect magisk 2 "Magisk 策略字段兼容"
expect inqs 1 "磁贴位于控制中心"
expect painted 运行中 "绘制标签字段兼容"
expect alive 1 "仅统计存活且 UID 相符的进程"
expect frozen 0 "确定可运行时才报告 frozen=0"
expect freezer '' "无冻结器线索仍保留原空值"
[ ! -e "$FIX/unexpected-control" ] && ok "只调用了沙箱 status，未调用 su / kill / 启停" || bad "触碰真实控制路径"

echo "== pm 缺失、失败、异常输出与确定未安装"
build; PM_RC=1; run_check
expect installed unknown "pm 失败不能当未安装"
build; : > "$FIX/packages"; run_check
expect installed 0 "成功空结果才是未安装"
build; printf 'package:com.ruin.magpie.tile.extra versionCode:1 uid:10330\n' > "$FIX/packages"; run_check
expect installed 0 "相似包名不能冒充磁贴 App"
build; printf 'Error: service unavailable\n' > "$FIX/packages"; run_check
expect installed unknown "零退出码的错误文本仍是未知"
build; printf 'package:com.ruin.magpie.tile versionCode:88\n' > "$FIX/packages"; run_check
expect installed unknown "缺失 UID 不能当未安装"
build; printf 'package:com.ruin.magpie.tile uid:10330\n' > "$FIX/packages"; run_check
expect vcode unknown "缺失版本号保留未知"

echo "== 关键命令失败不能借残留输出伪造正常结论"
build; SVC_RC=1; printf 'stopped\n' > "$FIX/svc"; run_check
expect svc unknown "status 非零退出不能报告 stopped"
build; QS_RC=1; run_check
expect inqs unknown "settings 失败不能报告未加入"
build; printf 'Error: denied\n' > "$FIX/qs"; run_check
expect inqs unknown "settings 错误文本不能报告未加入"
build; printf 'null\n' > "$FIX/qs"; run_check
expect inqs 0 "成功读取 null 列表可确定未加入"
build; DUMP_RC=1; run_check
expect painted unknown "dumpsys 失败保留未知"
build; SQL_RC=1; run_check
expect magisk unknown "可选 sqlite 失败保留未知"
build; rm "$B/bin/magisk"; run_check
expect magisk unknown "未安装 Magisk 也可完成体检，无重依赖"
build; : > "$FIX/sql"; run_check
expect magisk unknown "无策略记录不伪造允许或拒绝"

echo "== proc / cgroup 未知不会变成零"
build; rm "$FIX/proc/11/cgroup"; run_check
expect alive unknown "proc cgroup 读取失败时 alive 未知"
expect frozen unknown "proc cgroup 读取失败时 frozen 未知"
build; printf '2:cpu:/uid_10330/pid_11\n' > "$FIX/proc/11/cgroup"; run_check
expect alive unknown "无法识别的 cgroup 层级不当成死进程"
expect frozen unknown "无法识别的层级不当成未冻结"
build; rm "$FIX/cgroup/uid_10330/pid_11/cgroup.freeze"; run_check
expect alive 1 "冻结状态未知不丢失已确认的存活进程"
expect frozen unknown "cgroup.freeze 缺失不能报告未冻结"
build; printf 'bad\n' > "$FIX/cgroup/uid_10330/pid_11/cgroup.freeze"; run_check
expect frozen unknown "无效冻结值不能报告未冻结"
build; rm -rf "$FIX/cgroup/uid_10330"; run_check
expect alive unknown "无法访问 UID cgroup 时存活数未知"
expect frozen unknown "无法访问 UID cgroup 时冻结数未知"
build; LS_RC=1; run_check
expect alive unknown "cgroup 枚举失败保留未知"
expect frozen unknown "cgroup 枚举失败不报告零冻结"
build; rm -rf "$FIX/proc/11"; run_check
expect alive 0 "已死 PID 的 cgroup 残留可确定跳过"
expect frozen 0 "仅有已死残留时冻结数为零"
build; printf '0::/uid_90000/pid_11\n' > "$FIX/proc/11/cgroup"; run_check
expect alive 0 "其他 UID 的沙箱进程不能计入磁贴"
build; printf '1\n' > "$FIX/cgroup/uid_10330/pid_11/cgroup.freeze"; run_check
expect frozen 1 "确定冻结时正常报告数量"
build; mkdir -p "$FIX/cgroup/uid_10330/pid_12" "$FIX/proc/12"; run_check
expect alive unknown "部分 proc 不可读时不能把可读子集当完整数量"
expect frozen unknown "部分 proc 不可读时不能推断全部未冻结"

echo "== 模块缺失与访问失败分开"
build; rm -rf "$FIX/modules/magpie"; run_check
expect mod 0 "可读模块目录内不存在本模块才报告未安装"
build; rm -rf "$FIX/modules"; run_check
expect mod unknown "模块父目录不可访问时报告未知"

echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = 0 ] || exit 1
