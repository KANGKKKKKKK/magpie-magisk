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
"$HOST_CAT" "$FIX/dump" || exit $?
# 若解析器提前退出导致 SIGPIPE，就到不了这里；大输出用例据此确认消费到尾。
: > "$FIX/dump-consumed"
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
for _cmd in cat sed grep head tr awk; do
  ln -s "$(command -v "$_cmd")" "$B/bin/$_cmd"
done
MOCK_PATH="$B/bin"

# Linux sh 的内置 printf 没有 Android 外部 /system/bin/printf 的 argv 上限。
# 用 shell 函数先拦截单参数 >=128 KiB，不能依赖 PATH 外部桩覆盖内置命令。
cat > "$B/printf-limit.sh" <<'MOCK'
printf() {
  for _printf_arg do
    if [ "${#_printf_arg}" -ge 131072 ]; then
      : > "$FIX/printf-arg-too-long"
      echo 'printf: Argument list too long' >&2
      return 126
    fi
  done
  command printf "$@"
}
MOCK
cat > "$B/run-check.sh" <<'MOCK'
. "$1"
. "$2"
MOCK

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
  OUT=$(PATH="$MOCK_PATH" "$HOST_SH" "$B/run-check.sh" "$B/printf-limit.sh" "$B/check.sh" 2>"$B/check.err"); RC=$?
  if [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | tail -1)" = done=1 ] && [ "$(get 'done')" = 1 ] && [ ! -e "$FIX/printf-arg-too-long" ]; then
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

echo "== dumpsys 流式读取与 Android printf 单参数边界"
# 先证明边界替身确实生效；超长值只进 shell 函数，绝不传给外部 printf。
build
awk 'BEGIN { for (i = 0; i < 131072; i++) printf "x" }' > "$FIX/oversize-arg"
PATH="$MOCK_PATH" "$HOST_SH" -c '. "$1"; _arg=$(cat "$FIX/oversize-arg"); printf "%s" "$_arg"' sh "$B/printf-limit.sh" > /dev/null 2> "$B/limit.err"
_LIMIT_RC=$?
[ "$_LIMIT_RC" = 126 ] && [ -f "$FIX/printf-arg-too-long" ] && grep -q 'Argument list too long' "$B/limit.err" && ok "printf 函数可靠模拟 Android 的 128 KiB 单参数失败" || bad "printf 边界替身未生效"

large_dump() {
  # 超过 512 KiB，目标在头部；解析器找到 label 也必须继续消费到尾。
  {
    printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]\n'
    awk 'BEGIN { for (i = 0; i < 8192; i++) print "unrelated-systemui-data-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789" }'
    printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=已停止,more=value]\n'
  } > "$FIX/dump"
}
build; large_dump
[ "$(wc -c < "$FIX/dump")" -gt 262144 ] && ok "大 dumpsys 夹具确实超过 256 KiB" || bad "大输出夹具不足 256 KiB"
run_check
expect painted 运行中 "大输出成功仍返回首个目标 label，不触发外部 printf argv 上限"
[ -f "$FIX/dump-consumed" ] && [ ! -s "$B/check.err" ] && ok "找到首个目标后仍完整消费大输出且没有 printf 报错" || bad "提前停读或出现参数过长错误"
build; large_dump; DUMP_RC=7; run_check
expect painted unknown "大输出带合法 label 但最终非零退出必须 unknown"
[ -f "$FIX/dump-consumed" ] && ok "失败 dump 的大正文也完整消费到尾再检查退出状态" || bad "失败大输出未完整消费"
build
awk 'BEGIN { for (i = 0; i < 8192; i++) print "unrelated-systemui-data-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789" }' > "$FIX/dump"
printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=已停止,more=value]\n' >> "$FIX/dump"
run_check
expect painted 已停止 "目标位于超过 256 KiB 的尾部时仍能找到"
build
awk 'BEGIN { for (i = 0; i < 300000; i++) printf "x" }' > "$FIX/dump"
printf ' spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]\n' >> "$FIX/dump"
run_check
expect painted 运行中 "单行超过 256 KiB 也不把整行送进 shell argv"

# 无结尾换行时也不能把退出哨兵粘在最后一条记录上。
build; printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]' > "$FIX/dump"; run_check
expect painted 运行中 "成功 dump 不带结尾换行仍能解析"
build; printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]' > "$FIX/dump"; DUMP_RC=1; run_check
expect painted unknown "失败 dump 不带结尾换行仍可靠报告 unknown"
build; large_dump
printf '__MAGPIE_DUMP_RC__=0\n' >> "$FIX/dump"
DUMP_RC=3; run_check
expect painted unknown "正文中的伪成功哨兵不能覆盖真实退出失败"

echo "== painted 多目标、空标签、无目标与畸形内容"
build
printf '%s\n' \
  'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]' \
  'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=已停止,more=value]' > "$FIX/dump"
run_check
expect painted 运行中 "多行多个目标保留首个合法标签"
build
printf '%s\n' 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=已停止,more=x] spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=y]' > "$FIX/dump"
run_check
expect painted 已停止 "同一行多个目标不贪婪地取到后一个标签"
build
printf '%s\n' \
  'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=,more=value]' \
  'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]' > "$FIX/dump"
run_check
expect painted '' "合法空 label 保留为空，不能被后一个标签覆盖"
build; printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=null,more=value]\n' > "$FIX/dump"; run_check
expect painted null "null label 保留原值供界面判断尚未绘制"
build; printf 'spec=custom(com.ruin.magpie.tile/com.ruin.magpie.tile.MagpieTileService),secondaryLabel=运行中,more=value]\n' > "$FIX/dump"; run_check
expect painted 运行中 "同一目标的完整类名写法仍可解析"
build
printf '%s\n' \
  'spec=custom(com.ruin.magpie.tile.extra/.MagpieTileService),secondaryLabel=错误包,more=value]' \
  'spec=custom(com.ruin.magpie.tile/.OtherService),secondaryLabel=错误类,more=value]' \
  'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value]' > "$FIX/dump"
run_check
expect painted 运行中 "相似包名与其他组件不能抢占目标标签"
build
printf '%s\n' \
  'spec=custom(com.ruin.magpie.tile/.MagpieTileService),label=没有副标签,more=value]' \
  'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=已停止,more=value]' > "$FIX/dump"
run_check
expect painted 已停止 "缺少 secondaryLabel 的记录跳过并继续找合法目标"
build; : > "$FIX/dump"; run_check
expect painted unknown "成功空 dump 不是确定的空标签"
build; printf 'spec=custom(com.example/.Tile),secondaryLabel=运行中,more=value]\n' > "$FIX/dump"; run_check
expect painted unknown "成功但没有目标时保持 unknown"
build; printf 'Error: permission denied\n' > "$FIX/dump"; run_check
expect painted unknown "零退出的错误文本仍不能冒充空标签"
build; printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),label=运行中,more=value]\n' > "$FIX/dump"; run_check
expect painted unknown "目标缺少 secondaryLabel 时保持 unknown"
build; printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中,more=value\n' > "$FIX/dump"; run_check
expect painted unknown "目标记录缺少闭合括号时拒绝残缺内容"
build; printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行中]\n' > "$FIX/dump"; run_check
expect painted unknown "缺少字段结束分隔符时拒绝畸形标签"
build; printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel=运行\t中,more=value]\n' > "$FIX/dump"; run_check
expect painted unknown "控制字符标签不能污染单行自查协议"
build
{
  printf 'spec=custom(com.ruin.magpie.tile/.MagpieTileService),secondaryLabel='
  awk 'BEGIN { for (i = 0; i < 150000; i++) printf "x" }'
  printf ',more=value]\n'
} > "$FIX/dump"
run_check
expect painted unknown "畸形超长 label 不捕获到 shell，也不会触发 argv 上限"
# 解析器本身失败也必须 unknown，不能借空输出伪造空 label。
build; rm "$B/bin/awk"; printf '#!/bin/sh\nexit 4\n' > "$B/bin/awk"; chmod 755 "$B/bin/awk"; run_check
expect painted unknown "awk 解析失败时可靠回退 unknown"
rm "$B/bin/awk"; ln -s "$(command -v awk)" "$B/bin/awk"

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
