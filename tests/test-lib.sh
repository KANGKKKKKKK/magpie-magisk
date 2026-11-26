#!/bin/sh
# lib.sh 里纯函数的表驱动测试
#
# 这些函数是「地址写错 → 状态页整份坏掉」那类 bug 的唯一入口：
#   1. addr_host / addr_port —— 配置写成 127.0.0.1（漏端口）、端口越界、
#      IPv6 的 [::1]:3425 都要被正确切开或判错
#   2. is_loopback_host —— 回环判定不统一时，配 ::1 会被报成「已对局域网开放」
#   3. is_ip_addr 家族 —— MAGPIE_DNS 里写错的项必须被拦住
#   4. json_str —— 键里出现引号/反斜杠时 status.json 不能变成非法 JSON
#
# 全是纯函数，不碰真实进程和文件。
# 用法: sh tests/test-lib.sh
#
# 注意：变量名一律 ASCII —— busybox ash / mksh 不支持多字节变量名
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LIB=${TEST_LIB:-$HERE/../scripts/lib.sh}
# 临时目录：Android 上没有 /tmp，退到 TMPDIR 或 /data/local/tmp。
# 后面生成用户配置那组要用（别处几套测试各自定义了同名变量，
# 但这个文件是独立的，得自己有一份）。
if [ -d /tmp ] && [ -w /tmp ]; then
  _TMPBASE=/tmp
else
  _TMPBASE=${TMPDIR:-/data/local/tmp}
fi
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

[ -f "$LIB" ] || { echo "找不到 $LIB"; exit 2; }
# shellcheck disable=SC1090
. "$LIB"

# 断言 addr_host 的输出
expect_host() {
  _want=$1; _in=$2
  _got=$(addr_host "$_in")
  if [ "$_got" = "$_want" ]; then ok "host($_in) = $_got" ; else bad "host($_in) = [$_got]，期望 [$_want]"; fi
}

# 断言 addr_port 的结果；期望值为 "-" 表示应当返回非零
expect_port() {
  _want=$1; _in=$2
  _got=$(addr_port "$_in" 2>/dev/null); _rc=$?
  if [ "$_want" = "-" ]; then
    [ "$_rc" -ne 0 ] && ok "port($_in) 被拒" || bad "port($_in) 应为非法，却给出 [$_got]"
  else
    [ "$_rc" -eq 0 ] && [ "$_got" = "$_want" ] && ok "port($_in) = $_got" \
      || bad "port($_in) = [$_got] rc=$_rc，期望 [$_want]"
  fi
}

# 断言布尔函数（0/1）
expect_bool() {
  _want=$1; _in=$2; _fn=$3
  if "$_fn" "$_in" >/dev/null 2>&1; then _got=Y; else _got=N; fi
  if [ "$_got" = "$_want" ]; then ok "$_fn($_in) = $_want"
  else bad "$_fn($_in) = $_got，期望 $_want"; fi
}

echo "== 1 地址切分：host"
expect_host 127.0.0.1    "127.0.0.1:3425"
expect_host 0.0.0.0      "0.0.0.0:3425"
expect_host localhost    "localhost:3425"
expect_host 192.168.1.5  "192.168.1.5:3430"
expect_host ::1          "[::1]:3425"
expect_host 2001:db8::1  "[2001:db8::1]:80"
expect_host ::1          "[::1]"
expect_host ""           ":3425"

echo "== 2 地址切分：端口"
expect_port 3425   "127.0.0.1:3425"
expect_port 65535  "127.0.0.1:65535"
expect_port 3430   "[::1]:3430"
expect_port -      "127.0.0.1"          # 漏端口：这正是写出非法 JSON 的那个配置
expect_port -      "127.0.0.1:"
expect_port -      "127.0.0.1:0"
expect_port -      "127.0.0.1:65536"
expect_port -      "127.0.0.1:99999"
expect_port -      "127.0.0.1:abc"
expect_port -      "127.0.0.1:-1"
expect_port -      "127.0.0.1:12 34"
expect_port -      "[::1]"
expect_port -      ""

echo "== 3 回环判定"
for h in 127.0.0.1 127.1.2.3 localhost ::1 "[::1]" 0:0:0:0:0:0:0:1; do
  expect_bool Y "$h" is_loopback_host
done
for h in 0.0.0.0 "" 192.168.1.5 :: 2001:db8::1 "[::]"; do
  expect_bool N "$h" is_loopback_host
done

echo "== 4 IPv4"
for a in 223.5.5.5 1.1.1.1 8.8.8.8 0.0.0.0 255.255.255.255 192.168.1.1; do
  expect_bool Y "$a" is_ipv4_addr
done
for a in 256.1.1.1 999.999.999.999 1.2.3 1.2.3.4.5 1..2.3 .1.2.3 1.2.3. \
         abc 01.2.3.4 1.2.3.04 "" 1.2.3.4:53; do
  expect_bool N "$a" is_ipv4_addr
done

echo "== 5 IPv6"
for a in ::1 :: 2001:4860:4860::8888 2001:4860:4860:0:0:0:0:8888 fe80::1 ::ffff:192.168.1.1; do
  expect_bool Y "$a" is_ipv6_addr
done
for a in 1::2::3 ::: ::1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:8:9 12345::1 \
         ::ffff:999.1.1.1 "fe80::1%wlan0" "" 1.2.3.4; do
  expect_bool N "$a" is_ipv6_addr
done

echo "== 6 统一入口 is_ip_addr"
for a in 223.5.5.5 ::1 2001:db8::1; do expect_bool Y "$a" is_ip_addr; done
for a in abc example.com 1.2.3 999.1.1.1 ""; do expect_bool N "$a" is_ip_addr; done

echo "== 7 MAGPIE_DNS 过滤"
body=$(magpie_resolv_body "223.5.5.5 abc 999.999.999.999 8.8.8 1.1.1.1 ::1")
n=$(printf '%s\n' "$body" | grep -c '^nameserver ')
if [ "$n" = "3" ]; then ok "3 个合法项被留下"; else bad "留下了 $n 项，期望 3：$body"; fi
case "$body" in *"nameserver abc"*) bad "abc 不该被写进 resolv.conf" ;; *) ok "非法项 abc 被跳过" ;; esac
case "$body" in *"nameserver 999.999.999.999"*) bad "越界 IPv4 不该被写进去" ;; *) ok "越界 IPv4 被跳过" ;; esac
case "$body" in *"options timeout:2 attempts:2"*) ok "options 行仍在" ;; *) bad "丢了 options 行" ;; esac

bad_list=$(magpie_bad_dns "223.5.5.5 abc 8.8.8" | tr '\n' ' ')
if [ "$bad_list" = "abc 8.8.8 " ]; then ok "被跳过的项能逐个点名"; else bad "点名结果不对：[$bad_list]"; fi

# 一条都不合法时只剩 options 行 —— 调用方据此保留旧配置
body=$(magpie_resolv_body "abc junk")
case "$body" in *"nameserver "*) bad "全非法时不该产出 nameserver" ;; *) ok "全非法时没有 nameserver 行" ;; esac

echo "== 8 JSON 转义"
out=$(json_str 'a"b\c')
if [ "$out" = 'a\"b\\c' ]; then ok "引号与反斜杠被转义"; else bad "转义结果不对：[$out]"; fi
out=$(json_str "$(printf 'line1\nline2')")
case "$out" in *"
"*) bad "换行没被去掉，会破坏 JSON" ;; *) ok "换行被去掉" ;; esac
# 真实拼进 JSON 再解析一遍（有 python3 才验）
if command -v python3 >/dev/null 2>&1; then
  if printf '{"k":"%s"}' "$(json_str 'a"b\c')" \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["k"] == "a\"b\\c" else 1)' 2>/dev/null; then
    ok "拼进 JSON 后仍可解析"
  else
    bad "拼进 JSON 后解析失败"
  fi
fi

echo "== 9 夹具地址可配（make-fixtures --base）"
# 端口写死过 8899：换端口跑测试会得到一堆假失败，这条防回归
if command -v python3 >/dev/null 2>&1; then
# 临时目录：Android 上没有 /tmp，退到 TMPDIR 或 /data/local/tmp
if [ -d /tmp ] && [ -w /tmp ]; then
  _TMPBASE=/tmp
else
  _TMPBASE=${TMPDIR:-/data/local/tmp}
fi
  _fx="${TEST_BASE:-$_TMPBASE/magpie-lib-test}/fx"
  rm -rf "$_fx"
  if python3 "$HERE/make-fixtures.py" "$_fx" --base http://127.0.0.1:18999 >/dev/null 2>&1; then
    if grep -q '127\.0\.0\.1:18999' "$_fx/manifest.json" 2>/dev/null \
       && ! grep -q ':8899' "$_fx/manifest.json" 2>/dev/null; then
      ok "清单里的地址跟着 --base 走"
    else
      bad "清单地址没跟着 --base 走"
    fi
  else
    bad "make-fixtures.py --base 执行失败"
  fi
  rm -rf "$_fx"
else
  echo "  SKIP  没有 python3，跳过"
fi

echo "== 10 发布 tag 形状"
# release.yml 以前用 case 的 glob 判断 v[0-9]*.[0-9]*，
# 除 . 和 [] 外都是通配符，v1junk.2、v1.2.3.4.5 都能过。
for t in v0.5 v0.9.2 v0.9.2.1 v1.2.3.4 v10.20.30; do
  if is_valid_release_tag "$t"; then ok "tag($t) 接受"; else bad "tag($t) 被误拒"; fi
done
for t in v.2 v0 v1junk.2 v0.9. 'v0.9 2' v1.2.3.4.5 v0..9 0.9.2 V1.2 v-1.2 v0.9.x 1234.5 ''; do
  if is_valid_release_tag "$t"; then bad "tag([$t]) 被误接受"; else ok "tag([$t]) 被拒"; fi
done

echo "== 11 CA 证书包合并"
# 这段逻辑本来在 magpie.service 和 magpie-cli.sh 各有一份，抽到 lib.sh 后
# 必须确认它仍然「先写临时文件、校验通过才替换」—— 重建失败把能用的旧包
# 弄没，会让本来正常的 HTTPS 突然全挂。
_ca=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ca-$$")
mkdir -p "$_ca/cacerts" 2>/dev/null
# 造两段看起来像证书的内容，够 grep BEGIN CERTIFICATE 通过
printf -- '-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n' > "$_ca/cacerts/aaa.0"
printf -- '-----BEGIN CERTIFICATE-----\nBBB\n-----END CERTIFICATE-----\n' > "$_ca/cacerts/bbb.0"

_magpie_ca_dirs_save=$MAGPIE_CA_DIRS
MAGPIE_CA_DIRS="$_ca/cacerts"
_fp1=$(magpie_ca_fingerprint)
case "$_fp1" in *cacerts=2/*) ok "指纹含目录与文件数" ;; *) bad "指纹不对：[$_fp1]" ;; esac

_n=$(magpie_write_ca_bundle "$_ca/out.crt"); _rc=$?
if [ "$_rc" = "0" ] && [ "$_n" = "2" ]; then ok "合并出 2 张证书"
else bad "合并结果 rc=$_rc n=$_n"; fi
[ -s "$_ca/out.crt" ] && ok "证书包已落盘" || bad "证书包没生成"

# 没有可用证书时必须失败，且不能动已有的包
_sha_before=$(sha256sum "$_ca/out.crt" 2>/dev/null | awk '{print $1}')
MAGPIE_CA_DIRS="$_ca/empty-not-here"
if magpie_write_ca_bundle "$_ca/out.crt" >/dev/null 2>&1; then
  bad "没有证书时不该返回成功"
else
  ok "没有可用证书时返回失败"
fi
_sha_after=$(sha256sum "$_ca/out.crt" 2>/dev/null | awk '{print $1}')
if [ -n "$_sha_before" ] && [ "$_sha_before" = "$_sha_after" ]; then
  ok "失败时没有覆盖已有的包"
else
  bad "失败时把原包改了"
fi
# 不留下临时文件
case "$(ls "$_ca" 2>/dev/null | tr '\n' ' ')" in
  *out.crt.tmp*) bad "留下了临时文件" ;;
  *) ok "没有残留临时文件" ;;
esac
MAGPIE_CA_DIRS=$_magpie_ca_dirs_save
rm -rf "$_ca" 2>/dev/null

echo "== 12 日志轮转"
_rl=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rl-$$")
mkdir -p "$_rl" 2>/dev/null
printf 'x' > "$_rl/a.log"
magpie_rotate_log "$_rl/a.log" 1000
[ -s "$_rl/a.log" ] && ok "没超阈值时不轮转" || bad "没超阈值却轮转了"
# 造一个超过阈值的文件
i=0; while [ "$i" -lt 20 ]; do printf 'yyyyyyyyyy' >> "$_rl/a.log"; i=$((i + 1)); done
magpie_rotate_log "$_rl/a.log" 100
if [ -f "$_rl/a.log.1" ] && [ ! -s "$_rl/a.log" ]; then ok "超阈值时归档并清空"
else bad "轮转结果不对（.1 存在=$( [ -f "$_rl/a.log.1" ] && echo y || echo n) 大小=$(stat -c %s "$_rl/a.log" 2>/dev/null)）"; fi
rm -rf "$_rl" 2>/dev/null

echo "== 13 磁贴 App 的版本比较"
# tile-app.sh 决定「要不要装/更新」。判错的方向只有两种：
# 该更新时不动（用户永远拿不到新版），或不该动时重装（每次开机都装一遍）。
_ta=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ta-$$")
mkdir -p "$_ta/bin"
cp "$HERE/../scripts/tile-app.sh" "$_ta/"
printf '#!/bin/sh\ncase "$1" in\n  dump) [ -n "${FAKE_CODE:-}" ] && echo "    versionCode=${FAKE_CODE}" ;;\n  install) echo Success ;;\n  uninstall) echo Success ;;\nesac\n' > "$_ta/bin/pm"
chmod 755 "$_ta/bin/pm"
echo 2 > "$_ta/tile-version"
: > "$_ta/magpie-tile.apk"

# 没装 → 装
_r=$(PATH="$_ta/bin:$PATH" FAKE_CODE= sh -c ". '$_ta/tile-app.sh'; tile_install '$_ta'" 2>&1)
case "$_r" in *已安装*) ok "没装过时执行安装" ;; *) bad "没装过时没装：$_r" ;; esac

# 同版本 → 跳过
_r=$(PATH="$_ta/bin:$PATH" FAKE_CODE=2 sh -c ". '$_ta/tile-app.sh'; tile_install '$_ta'" 2>&1)
case "$_r" in *已是最新*) ok "同版本时跳过" ;; *) bad "同版本时重装了：$_r" ;; esac

# 旧版本 → 更新
_r=$(PATH="$_ta/bin:$PATH" FAKE_CODE=1 sh -c ". '$_ta/tile-app.sh'; tile_install '$_ta'" 2>&1)
case "$_r" in *已安装*) ok "旧版本时更新" ;; *) bad "旧版本时没更新：$_r" ;; esac

# 比模块新 → 不动（用户可能手动装过更新的）
_r=$(PATH="$_ta/bin:$PATH" FAKE_CODE=5 sh -c ". '$_ta/tile-app.sh'; tile_install '$_ta'" 2>&1)
case "$_r" in *已是最新*) ok "已装版本更新时不动" ;; *) bad "把更新的版本降级了：$_r" ;; esac

rm -rf "$_ta" 2>/dev/null

echo "== 14 磁贴 App 的桌面图标开关（activity-alias）"
# 隐藏图标靠关闭 activity-alias 实现，MainActivity 必须保持可启动，
# 否则用户再也进不来设置页、也没法把图标恢复回来。
_ma="$HERE/../tile-app/AndroidManifest.xml"
if [ -f "$_ma" ]; then
  # LAUNCHER 入口必须挂在 alias 上，不能挂在 MainActivity 上
  if grep -q 'android:name=".Launcher"' "$_ma" && grep -q 'activity-alias' "$_ma"; then
    ok "桌面入口由 activity-alias 承载"
  else
    bad "没找到 activity-alias，隐藏图标会连设置页一起关掉"
  fi
  # alias 要指向 MainActivity
  if grep -A3 'activity-alias' "$_ma" | grep -q 'targetActivity=".MainActivity"'; then
    ok "alias 指向 MainActivity"
  else
    bad "alias 的 targetActivity 不是 MainActivity"
  fi
  # MainActivity 自身不能带 LAUNCHER 类别（否则关掉 alias 图标还在）。
  # 注意它是自闭合标签 <activity ... />，不能按「到 </activity>」的范围取 ——
  # 那样会把后面的 activity-alias 也吃进来，误报。
  _act=$(awk '/<activity$/{f=1} f{print} f&&/\/>$/{exit} f&&/<\/activity>/{exit}' "$_ma")
  case "$_act" in
    *LAUNCHER*) bad "MainActivity 自己声明了 LAUNCHER，隐藏图标会失效" ;;
    *) ok "MainActivity 不带 LAUNCHER 类别" ;;
  esac
  # 磁贴长按的恢复入口：TileService 没有 onLongClick（android-34 的 API 里
  # 只有 onClick / onStartListening / onStopListening），长按走的是
  # ACTION_QS_TILE_PREFERENCES 这个 Intent。必须有人接住它。
  if grep -q 'QS_TILE_PREFERENCES' "$_ma"; then
    ok "接住了 QS_TILE_PREFERENCES（图标隐藏后的恢复入口）"
  else
    bad "没有接 QS_TILE_PREFERENCES，隐藏图标后用户没法回到设置页"
  fi
else
  echo "  SKIP  没有 tile-app/AndroidManifest.xml"
fi

echo "== 15 路径白名单（卸载 / 安装共用）"
# 判定是「白名单」：只放行本模块自己的位置，其它一律拒绝。
# 守的是数据毁灭风险 —— 以前是枚举危险路径，漏一条就会 rm -rf 掉
# magisk.db、/data/misc/wifi（WiFi 密码）或 /data/user/0/*（与 /data/data 同一 inode）。
for bad in /data /data/ /data// /data/// /data/adb /data/adb/ /data/adb/modules \
           /data/adb/modules/ / /sdcard /sdcard/ /storage /storage/emulated/0 \
           /mnt /mnt/ /system /system/ /vendor /data/local /data/app /data/data /data/system \
           /data/adb/magisk /data/adb/ksu /data/adb/ap /data/adb/ksud \
           /data/adb/magisk.db /data/adb/post-fs-data.d /data/adb/service.d \
           /data/misc /data/misc/wifi /data/user/0/com.example /data/user_de/0/com.example \
           /data/adb/modules/other /tmp/magpie-install-test \
           /data/local/tmp/magpie relative ''; do
  if magpie_path_cleanable "$bad"; then
    bad "危险路径被放行：[$bad]"
  else
    ok "拒绝删除 [$bad]"
  fi
done
# ".." 与重复斜杠：字符串归一化不够，rm -rf 执行时会做路径解析。
# /data/../data 在白名单里匹配不上 → 放行 → 实际删的是 /data。
for bad in /data/../data /data/foo/../data /data/adb/magpie/../../.. /data//adb /data/./adb /..; do
  if magpie_path_cleanable "$bad"; then
    bad "含 .. 的路径被放行：[$bad] → 实际会删 $(readlink -m "$bad" 2>/dev/null)"
  else
    ok "拒绝删除 [$bad]"
  fi
done

# 本模块自己的位置必须仍然可删
for good in /data/adb/magpie /data/adb/magpie/run /data/adb/magpie/data \
            /data/adb/modules/magpie /data/adb/modules/magpie/scripts; do
  if magpie_path_cleanable "$good"; then ok "允许删除 $good"
  else bad "把正常目标也拦了：$good"; fi
done

# 归一化本身
_n=$(magpie_norm_path "/data///") ; [ "$_n" = "/data" ] && ok "归一化 /data/// → /data" || bad "归一化结果不对：$_n"
_n=$(magpie_norm_path "///") ; [ "$_n" = "/" ] && ok "归一化 /// → /" || bad "归一化结果不对：$_n"

# 直接从 uninstall.sh 原文抽 cleanable 来跑：脚本与测试不会各改各的
_un="$HERE/../uninstall.sh"
if [ -f "$_un" ]; then
  eval "$(sed -n '/^cleanable()/,/^}/p' "$_un")"
  # 抽出来的 cleanable 依赖 lib.sh 里的实现（上面已 source），应能拦住 /data/
  if cleanable "/data/"; then bad "uninstall.sh 的 cleanable 放行了 /data/"; else ok "uninstall.sh 的 cleanable 拦住 /data/"; fi
  if cleanable "/data/adb/magpie"; then ok "uninstall.sh 的 cleanable 放行正常目标"; else bad "uninstall.sh 拦了正常目标"; fi
fi

# 同一份危险/正常路径表同时检验安装与清理；不可只测沙箱改过的 helper。
for _path in /data/adb/magisk /data/adb/magisk/bin /data/adb/ksu /data/adb/ap \
             /data/adb/ksud /data/adb/magisk.db /data/adb/post-fs-data.d /data/adb/service.d \
             /data/misc/wifi /data/user/0/com.example /data/user_de/0/com.example \
             /data/data/com.example /data/system /data/app /opt/magpie \
             /data/adb/magpie-custom /data/adb/modules/magpie2 \
             /data/adb/magpie/../../magisk /data/adb/modules/magpie/../other; do
  if magpie_path_installable "$_path" || magpie_path_cleanable "$_path"; then
    bad "安装/清理策略误放行 $_path"
  else
    ok "安装/清理策略均拒绝 $_path"
  fi
done
for _path in /data/adb/magpie /data/adb/magpie/data /data/adb/modules/magpie \
             /data/adb/modules/magpie/files; do
  if magpie_path_installable "$_path" && magpie_path_cleanable "$_path"; then
    ok "安装/清理策略均放行 $_path"
  else
    bad "安装/清理策略误拒绝 $_path"
  fi
done

# 抽取生产入口的同一函数，仅做校验，不调用下载、mkdir、锁或部署。
_ct=$(sed -n '/^check_target()/,/^}/p' "$HERE/../scripts/install.sh")
if [ -n "$_ct" ]; then
  for _path in /data/adb/magisk /data/adb/ksu /data/adb/service.d /data/misc/wifi \
               /data/user/0/com.example /opt/magpie /data/adb/magpie-custom \
               /data/adb/magpie/../magisk /data/adb/magpie/; do
    # 派生变量按真实安装时的取值补齐；否则未定义变量会让函数提前报错，
    # 任何路径都会被误当成「已拒绝」，测试就变成了假绿。
    if ( eval "$_ct"; die() { exit 1; }
         BIN_DIR="$_path/bin"; BIN="$_path/bin/magpie"; BAK="$_path/bin/magpie.bak"
         INFO="$_path/install-info.txt"; LOCK="$_path/.install.lock"
         PENDING="$_path/.install.pending"
         magpie_path="$_path"; check_target ) >/dev/null 2>&1; then
      bad "生产 check_target 误放行 $_path"
    else
      ok "生产 check_target 拒绝 $_path（未触碰目标）"
    fi
  done
else
  bad "未能从生产安装器抽取 check_target"
fi

echo "== 16 IPv6 回环的大小写"
# IPv6 十六进制位大小写不敏感。以前只匹配小写，::FFFF:127.0.0.1 会被判成
# 「已开放局域网」—— 安全边界的结论说反了。
for h in ::1 ::FFFF:127.0.0.1 ::ffff:127.0.0.1 ::FFFF:127.1.2.3 0:0:0:0:0:0:0:1 \
         127.0.0.1 127.1.2.3 LOCALHOST localhost '[::1]'; do
  if is_loopback_host "$h"; then ok "[$h] 判为回环"; else bad "[$h] 被误判成非回环"; fi
done
for h in ::ffff:192.168.1.1 ::FFFF:8.8.8.8 0.0.0.0 192.168.1.1; do
  if is_loopback_host "$h"; then bad "[$h] 被误判成回环（安全边界说反）"; else ok "[$h] 判为非回环"; fi
done

echo "== 17 用户配置的生成（seed_user_config）"
# README 让用户改 /data/adb/magpie/scripts/magpie.config，但以前没人创建它。
# 这里直接从 service.sh 原文抽函数来跑，脚本改了测试会跟着改。
_sd="${TEST_BASE:-$_TMPBASE/magpie-seed-test}"
rm -rf "$_sd"; mkdir -p "$_sd/scripts" "$_sd/run"
cp "$HERE/../scripts/magpie.config" "$_sd/scripts/magpie.config"
: > "$_sd/run/w.log"
if grep -q '^seed_user_config()' "$HERE/../service.sh"; then
  MP="$_sd/data"; MODDIR="$_sd"; WATCH_LOG="$_sd/run/w.log"
  eval "$(sed -n '/^seed_user_config()/,/^}/p' "$HERE/../service.sh")"
  seed_user_config
  _cfg="$MP/scripts/magpie.config"
  [ -f "$_cfg" ] && ok "首次调用生成了用户配置" || bad "没有生成用户配置"
  _perm=$(stat -c %a "$_cfg" 2>/dev/null)
  [ "$_perm" = "600" ] && ok "权限 600" || bad "权限是 $_perm，应为 600"
  # 用户改过之后不能再被覆盖
  echo "# 用户改过" >> "$_cfg"
  seed_user_config
  if [ "$(tail -1 "$_cfg")" = "# 用户改过" ]; then ok "已存在时不覆盖用户改动"
  else bad "把用户的配置覆盖掉了"; fi
  # 不留下临时文件
  case "$(ls "$MP/scripts" 2>/dev/null | tr '\n' ' ')" in
    *tmp*) bad "留下了临时文件" ;;
    *) ok "没有残留临时文件" ;;
  esac
  rm -rf "$_sd"
else
  bad "service.sh 里没有 seed_user_config"
fi

echo "== 18 桌面图标对账：限定包、User 0 与 disabled 小节"
_tl="${TEST_BASE:-$_TMPBASE}/magpie-tl-test"
rm -rf "$_tl"; mkdir -p "$_tl/bin" "$_tl/run"
cp "$HERE/../scripts/tile-app.sh" "$_tl/"
cat > "$_tl/bin/pm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CALLS"
case "$1" in
  dump) cat "$FAKE_DUMP"; exit "${FAKE_DUMP_RC:-0}" ;;
  disable) exit "${FAKE_DISABLE_RC:-0}" ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$_tl/bin/pm"
: > "$_tl/dump"; : > "$_tl/calls"
_r=$(PATH="$_tl/bin:$PATH" FAKE_DUMP="$_tl/dump" FAKE_CALLS="$_tl/calls" \
  sh -c ". '$_tl/tile-app.sh'; tile_reconcile_launcher '$_tl/run'" 2>&1)
if [ -z "$_r" ] && [ ! -s "$_tl/calls" ]; then ok "没有标记时不调用任何 pm"
else bad "没有标记却调用 pm：$_r"; fi
: > "$_tl/run/.tile_launcher_hidden"

# 每个 case 从 stdin 取得完整层级 fixture；同时核对返回码、调用参数和次数。
check_tile_case() {
  _name=$1; _disable=$2; _dump_rc=${3:-0}; _disable_rc=${4:-0}
  cat > "$_tl/dump"; : > "$_tl/calls"
  _r=$(PATH="$_tl/bin:$PATH" FAKE_DUMP="$_tl/dump" FAKE_CALLS="$_tl/calls" \
    FAKE_DUMP_RC="$_dump_rc" FAKE_DISABLE_RC="$_disable_rc" \
    sh -c ". '$_tl/tile-app.sh'; tile_reconcile_launcher '$_tl/run'" 2>&1)
  _rc=$?
  _want='dump com.ruin.magpie.tile'
  if [ "$_disable" = 1 ]; then
    _want="$_want
disable --user 0 com.ruin.magpie.tile/.Launcher"
  fi
  _calls=$(cat "$_tl/calls")
  _expected_rc=0
  [ "$_disable" != 1 ] || _expected_rc=$_disable_rc
  if [ "$_calls" = "$_want" ] && [ "$_rc" = "$_expected_rc" ]; then
    if [ "$_disable" = 1 ] && [ "$_disable_rc" = 0 ]; then
      case "$_r" in *重新隐藏*) ok "$_name" ;; *) bad "$_name 未报告隐藏结果" ;; esac
    elif [ -z "$_r" ]; then ok "$_name"
    else bad "$_name 不应报告成功：$_r"; fi
  else
    bad "$_name（rc=$_rc；calls=$_calls）"
  fi
}
check_tile_case '空集合不打印 disabled 标题，补隐藏' 1 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
Queries:
EOF
check_tile_case 'User 0 disabled 精确类名，不重复操作' 0 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case 'enabled 小节不能冒充 disabled（无空行）' 1 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.MagpieTileService
      enabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case 'User 10 禁用不能代替 User 0' 1 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      enabledComponents:
        com.ruin.magpie.tile.Launcher
    User 10: installed=true
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case 'User 10 在前，User 0 已禁用仍正确识别' 0 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 10: installed=true
      enabledComponents:
        com.ruin.magpie.tile.Launcher
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case '其他包的同名条目不能命中' 1 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.MagpieTileService
  Package [com.example.other] (def):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case '同级未知小节不能穿透' 1 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.MagpieTileService
      otherSection:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case 'Queries 内的同名条目不能命中' 1 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.MagpieTileService
Queries:
    User 0:
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case '类名必须整行字面相等' 1 <<'EOF'
Packages:
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.LauncherExtra
        comXruinXmagpieXtileXLauncher
        com.ruin.magpie.tile/.Launcher
        com.ruin.magpie.tile.Launcher$Inner
EOF
printf '  Package [com.ruin.magpie.tile] (abc):\n    User 0: installed=true\n      disabledComponents:\n        com.ruin.magpie.tile.Launcher  \n' > "$_tl/whitespace"
check_tile_case '条目前后空白和 EOF 可识别' 0 < "$_tl/whitespace"
check_tile_case '只有 User 10 则补 User 0 隐藏' 1 <<'EOF'
  Package [com.ruin.magpie.tile] (abc):
    User 10: installed=true
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case '缺少包/用户上下文不得误报已隐藏' 1 <<'EOF'
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case 'dump 失败即使带匹配输出也应尝试隐藏' 1 1 <<'EOF'
  Package [com.ruin.magpie.tile] (abc):
    User 0: installed=true
      disabledComponents:
        com.ruin.magpie.tile.Launcher
EOF
check_tile_case '空 dump 输出安全退回补隐藏' 1 </dev/null
check_tile_case 'disable 失败返回非零且不谎报成功' 1 0 1 </dev/null
rm -rf "$_tl"


echo "== 进程身份：fake /proc，精确 argv[1] 与共享本体过滤"
_pt=$(mktemp -d "$_TMPBASE/magpie-lib-proc.XXXXXX") || exit 1
mkdir -p "$_pt/proc" "$_pt/owned/bin" "$_pt/foreign/bin"
sed "s#/proc/#$_pt/proc/#g" "$LIB" > "$_pt/lib.sh"
proc_set() {
  _pt_pid=$1; _pt_exe=$2; shift 2
  mkdir -p "$_pt/proc/$_pt_pid"
  rm -f "$_pt/proc/$_pt_pid/exe"
  ln -s "$_pt_exe" "$_pt/proc/$_pt_pid/exe"
  printf '%s\000' "$@" > "$_pt/proc/$_pt_pid/cmdline"
}
proc_call() (
  # 模拟 doctor 先 source、后读配置；不依赖服务控制器的 BIN。
  . "$_pt/lib.sh"
  unset BIN magpie_path
  # 动态 source 的进程 helper 在调用时读取这些配置，不是未使用的变量。
  # shellcheck disable=SC2034
  case "$1" in
    default) ;;
    bin) BIN="$_pt/foreign/bin/magpie"; magpie_path="$_pt/owned" ;;
    emptybin) BIN=""; magpie_path="$_pt/owned" ;;
    *) magpie_path="$_pt/owned" ;;
  esac
  shift
  pidof() { [ "$1" = magpie ] && cat "$_pt/candidates"; }
  magpie_all_pids() { : > "$_pt/forbidden-all"; echo 777; }
  case "$1" in
    main) magpie_main_pid ;;
    serves) magpie_command_pids serve ;;
    mcps) magpie_mcp_pids ;;
    match) shift; magpie_pid_command "$@" ;;
  esac
)
proc_expect() {
  _pt_want=$1; _pt_label=$2; shift 2
  _pt_out=$(proc_call "$@" 2>/dev/null); _pt_rc=$?
  if [ "$_pt_rc" = 0 ] && [ "$_pt_out" = "$_pt_want" ]; then ok "$_pt_label"
  else bad "$_pt_label（rc=$_pt_rc，结果=[$_pt_out]）"; fi
}
proc_reject() {
  _pt_label=$1; shift
  _pt_out=$(proc_call "$@" 2>/dev/null); _pt_rc=$?
  [ "$_pt_rc" -ne 0 ] && [ -z "$_pt_out" ] && ok "$_pt_label" || bad "$_pt_label（rc=$_pt_rc，结果=[$_pt_out]）"
}
printf '99 11 12 13 14 15 16 17 18 19 20 21\n' > "$_pt/candidates"
proc_set 11 "$_pt/owned/bin/magpie" magpie update --note 'serve mcp'
proc_set 12 "$_pt/owned/bin/magpie" magpie serve-extra
proc_set 13 "$_pt/foreign/bin/magpie" magpie serve
proc_set 14 "$_pt/owned/bin/magpie" magpie mcp vision
proc_set 15 "$_pt/owned/bin/magpie" magpie serve --web=x
proc_set 16 "$_pt/owned/bin/magpie" magpie serve
proc_set 17 "$_pt/owned/bin/magpie" magpie gateway-key mcp
proc_set 18 "$_pt/foreign/bin/magpie" magpie mcp
proc_set 19 "$_pt/owned/bin/magpie" magpie mcp search
proc_set 20 "$_pt/owned/bin/magpie" magpie serve
rm "$_pt/proc/20/cmdline"
proc_set 21 "$_pt/owned/bin/magpie" magpie serve
rm "$_pt/proc/21/exe"
proc_expect 15 '普通 CLI、伪 serve、其他本体在前仍找到真 serve' custom main
proc_expect "$(printf '15\n16')" '多个同名 serve 全部保留且不混入 CLI / MCP' custom serves
proc_expect "$(printf '14\n19')" 'MCP 使用同一精确过滤，不匹配 CLI 参数与外来本体' custom mcps
[ ! -e "$_pt/forbidden-all" ] && ok '进程清理候选不依赖 all_pids' || bad '使用了未经筛选的 all_pids'
proc_expect 15 'BIN 未定义时按后读取的自定义 magpie_path 识别' custom main
proc_expect 15 'BIN 为空时同样兼容只读调用者' emptybin main
proc_expect 13 '显式 BIN 优先于 magpie_path，只识别指定本体' bin main
proc_set 31 /data/adb/magpie/bin/magpie magpie serve
printf '11 31\n' > "$_pt/candidates"
proc_expect 31 'BIN 与 magpie_path 都未定义时使用默认本体路径' default main
proc_expect '' '可显式传第三参数选择本体，不依赖全局 BIN' custom match 13 serve "$_pt/foreign/bin/magpie"
proc_reject '普通 CLI 参数内 serve 不能冒充主命令' custom match 11 serve
proc_reject '普通 CLI 参数内 mcp 不能冒充子进程' custom match 17 mcp
proc_reject 'serve-extra 不等于 serve' custom match 12 serve
proc_reject '非本模块的同名 serve 不匹配' custom match 13 serve
proc_reject '无 cmdline 的过期候选失败关闭' custom match 20 serve
proc_reject '无 exe 的过期候选失败关闭' custom match 21 serve
proc_reject '负 PID 不得进入进程操作' custom match -1 serve
proc_reject '非数字 PID 不得进入进程操作' custom match 15x serve
proc_reject '只允许 serve / mcp 两个子命令' custom match 11 update
proc_set 22 "$_pt/owned/bin/magpie" "$(printf 'magpie\nserve')" update
proc_reject 'argv[0] 内的换行不能伪造 argv[1]' custom match 22 serve
proc_set 22 "$_pt/owned/bin/magpie" magpie "$(printf 'serve\nextra')"
proc_reject 'argv[1] 内的换行不能截成 serve' custom match 22 serve
proc_set 22 "$_pt/owned/bin/magpie" magpie '' serve
proc_reject '空 argv[1] 后的 serve 仍是参数' custom match 22 serve
proc_set 22 "$_pt/owned/bin/magpie" magpie
proc_reject '不存在 argv[1] 不得匹配' custom match 22 serve
proc_set 23 "$_pt/owned/bin/magpie (deleted)" magpie serve
proc_expect '' '覆盖升级后持有已删除本体的 serve 仍可识别' custom match 23 serve
: > "$_pt/owned/bin/real-magpie"; ln -s "$_pt/owned/bin/real-magpie" "$_pt/owned/bin/magpie"
proc_set 24 "$_pt/owned/bin/real-magpie" magpie mcp
proc_expect '' '经符号链接调用的本体可识别' custom match 24 mcp
proc_set 24 "$_pt/owned/bin/real-magpie (deleted)" magpie mcp
proc_expect '' '经符号链接升级后的旧本体可识别' custom match 24 mcp
printf '11 15 16\n' > "$_pt/candidates"
proc_set 15 "$_pt/owned/bin/magpie" magpie update serve
proc_expect 16 '首个真 serve 换成 CLI 后继续找到后面的真 serve' custom main
proc_expect 16 '全量枚举同步跳过已换身份的首个候选' custom serves
proc_set 16 "$_pt/foreign/bin/magpie" magpie serve
proc_reject '只剩普通 CLI / 外来本体时主进程探测返回非零' custom main
proc_reject '只剩伪候选时全量 serve 枚举返回非零' custom serves
printf '99\n' > "$_pt/candidates"
proc_reject '只有已经消失的候选时 MCP 枚举返回非零' custom mcps
rm -rf "$_pt"

echo
echo "结果： PASS $PASS ， FAIL $FAIL"

[ "$FAIL" = "0" ] || exit 1
