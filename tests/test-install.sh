#!/bin/sh
# install.sh 的沙箱测试：不改真实 magpie，全部在临时目录里跑
#
# 用法:
#   python3 tests/make-fixtures.py /tmp/fx
#   (cd /tmp/fx && python3 -m http.server 8899 &)
#   TEST_SRV=http://127.0.0.1:8899 sh tests/test-install.sh
#
# 注意：变量名一律 ASCII —— busybox ash / mksh 不支持多字节变量名
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../scripts/install.sh"
SRV=${TEST_SRV:-}
# 临时目录：Android 上没有 /tmp，退到 TMPDIR 或 /data/local/tmp
if [ -d /tmp ] && [ -w /tmp ]; then
  _TMPBASE=/tmp
else
  _TMPBASE=${TMPDIR:-/data/local/tmp}
fi
BASE=${TEST_BASE:-$_TMPBASE/magpie-install-test}
PASS=0; FAIL=0

[ -n "$SRV" ] || { echo "请设置 TEST_SRV，例如 TEST_SRV=http://127.0.0.1:8899"; exit 2; }
# 清单里的下载地址是生成时写死的：换了端口就必须用 --base 重新生成，
# 否则会出现一堆「下载失败」的假失败。
echo "提示：夹具要与地址对应：python3 tests/make-fixtures.py <dir> --base $SRV"

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
step() { echo; echo "== $1"; }

# 每个用例一个干净沙箱
fresh() {
  rm -rf "$BASE"; mkdir -p "$BASE"
  sed "s#^CONF=.*#CONF=$BASE/cfg#" "$SRC" > "$BASE/install.sh"
  printf 'magpie_path="%s"\n' "$BASE" > "$BASE/cfg"
  chmod 755 "$BASE/install.sh"
}
run() { sh "$BASE/install.sh" "$@" 2>&1; }

export MAGPIE_MANIFEST_URL="$SRV/manifest.json"
export MAGPIE_CONFIRM_WINDOW=600
# CI 与桌面都是 x86_64，架构闸门会挡掉所有用例；这里只是放行闸门，
# 其余逻辑（含"落盘的不是真能跑的本体就拒绝"）照常验证。
export MAGPIE_ALLOW_ANY_ARCH=1

step "1 未安装时的状态"
fresh
out=$(run status)
case "$out" in state=missing*) ok "识别为 missing" ;; *) bad "状态不对：$out" ;; esac

step "2 plan 能解析清单字段"
out=$(run plan)
echo "$out" | sed 's/^/     /'
case "$out" in *"将安装 magpie 9.9.9"*) ok "版本解析正确" ;; *) bad "版本没解析出来" ;; esac
case "$out" in *"下载大小  未知"*) bad "大小没解析出来" ;; *"下载大小"*) ok "大小解析正确" ;; *) bad "没有大小这一行" ;; esac

step "3 不带 --yes 只打印方案，不下载"
out=$(run install)
case "$out" in *"确认后才会下载"*) ok "进入二次确认" ;; *) bad "没有进入确认流程" ;; esac
[ -f "$BASE/.install.pending" ] && ok "写了待确认标记" || bad "没有待确认标记"
[ -f "$BASE/bin/magpie" ] && bad "不该下载却已落盘" || ok "没有提前落盘"

step "4 窗口内再执行一次才真正安装"
out=$(run install)
echo "$out" | sed 's/^/     /'
case "$out" in *"已安装 magpie 9.9.9"*) ok "安装完成并报出版本" ;; *) bad "安装没完成" ;; esac
[ -x "$BASE/bin/magpie" ] && ok "二进制可执行" || bad "二进制不可执行"
v=$(sh "$BASE/bin/magpie" --version 2>/dev/null)
[ "$v" = "magpie 9.9.9" ] && ok "落盘内容正确" || bad "落盘内容不对：$v"
[ -f "$BASE/install-info.txt" ] && ok "记录了安装信息" || bad "没记录安装信息"
[ -f "$BASE/.install.pending" ] && bad "确认标记应已清除" || ok "确认标记已清除"
[ -d "$BASE/.install.lock" ] && bad "锁没释放" || ok "锁已释放"

step "5 已就绪时默认不覆盖"
before=$(sha256sum "$BASE/bin/magpie" | awk '{print $1}')
out=$(run install)
case "$out" in *"不覆盖"*) ok "拒绝覆盖" ;; *) bad "没有拒绝覆盖：$out" ;; esac
after=$(sha256sum "$BASE/bin/magpie" | awk '{print $1}')
[ "$before" = "$after" ] && ok "文件未被改动" || bad "文件被改了"

step "6 status 报 ready"
out=$(run status)
case "$out" in state=ready*"9.9.9"*) ok "ready 且版本正确" ;; *) bad "状态不对：$out" ;; esac

step "7 sha256 不匹配时拒绝部署"
fresh
out=$(MAGPIE_MANIFEST_URL="$SRV/manifest-bad.json" run install --yes)
case "$out" in *"sha256 不匹配"*) ok "检出摘要不符" ;; *) bad "没有检出摘要不符" ;; esac
case "$out" in *"本体未改动"*) ok "明确说明本体未改动" ;; *) bad "没有说明结果" ;; esac
[ -f "$BASE/bin/magpie" ] && bad "不该产生正式文件" || ok "没有留下正式文件"
ls "$BASE/bin/".magpie.new.* >/dev/null 2>&1 && bad "临时文件没清" || ok "临时文件已清"

step "8 大小不符时拒绝部署"
fresh
out=$(MAGPIE_MANIFEST_URL="$SRV/manifest-badsize.json" run install --yes)
case "$out" in *"大小不符"*) ok "检出大小不符" ;; *) bad "没有检出大小不符" ;; esac

step "9 能下载但跑不起来：不留正式文件"
fresh
out=$(MAGPIE_MANIFEST_URL="$SRV/manifest-wrongarch.json" run install --yes)
case "$out" in *"跑不起来"*) ok "启动自检拦住了" ;; *) bad "没有拦住坏二进制" ;; esac
case "$out" in *"首次安装"*) ok "说明是首次安装无备份" ;; *) bad "没说明回退方式" ;; esac
[ -f "$BASE/bin/magpie" ] && bad "坏二进制留在了正式位置" || ok "正式位置没有留下坏二进制"
[ -f "$BASE/bin/magpie.rejected" ] && ok "失败样本另存备查" || bad "没有留下失败样本"

step "10 已有损坏本体：识别 broken 并重装修好"
fresh
mkdir -p "$BASE/bin"
printf 'this is not a binary\n' > "$BASE/bin/magpie"
chmod 755 "$BASE/bin/magpie"
out=$(run status)
case "$out" in state=broken*) ok "识别为 broken" ;; *) bad "状态不对：$out" ;; esac
out=$(run install --yes)
case "$out" in *"已安装 magpie 9.9.9"*) ok "重装成功" ;; *) bad "重装失败" ;; esac
[ -f "$BASE/bin/magpie.bak" ] && ok "留下了备份" || bad "没有备份"

step "11 rollback 能退回去"
out=$(run rollback)
case "$out" in *"已回退"*) ok "回退命令可用" ;; *) bad "回退失败：$out" ;; esac
out=$(run status)
case "$out" in state=broken*) ok "回退后确实变回损坏状态" ;; *) bad "回退没生效：$out" ;; esac

step "12 拒绝装到共享存储"
fresh
printf 'magpie_path="/sdcard/magpie-test"\n' > "$BASE/cfg"
out=$(run install --yes)
case "$out" in *"拒绝"*) ok "拒绝了 /sdcard" ;; *) bad "没有拒绝：$out" ;; esac

step "13 清单取不到时错误可理解"
fresh
out=$(MAGPIE_MANIFEST_URL="$SRV/nope.json" run install --yes)
case "$out" in *"取不到更新清单"*) ok "install 提示清晰" ;; *) bad "提示不清：$out" ;; esac
out=$(MAGPIE_MANIFEST_URL="$SRV/nope.json" run plan)
case "$out" in *"取不到更新清单"*) ok "plan 同样清晰" ;; *) bad "plan 提示不清：$out" ;; esac

step "14 并发安装被锁拦住"
fresh
mkdir -p "$BASE/.install.lock"
echo $$ > "$BASE/.install.lock/pid"
out=$(run install --yes)
case "$out" in *"另一个安装正在进行"*) ok "并发放行被拦" ;; *) bad "没有拦住并发：$out" ;; esac
rm -rf "$BASE/.install.lock"

step "15 过期锁能被清理"
mkdir -p "$BASE/.install.lock"
echo 999999 > "$BASE/.install.lock/pid"
out=$(run install --yes)
case "$out" in *"过期锁"*) ok "识别并清理了过期锁" ;; *) bad "没有处理过期锁：$out" ;; esac
case "$out" in *"已安装 magpie 9.9.9"*) ok "清理后安装成功" ;; *) bad "清理后仍失败" ;; esac

step "16 找不到下载器时的行为"
fresh
# 造一个「有常用工具但没有 wget/curl」的 PATH，逼它走兜底
mkdir -p "$BASE/nodl"
for t in sh awk sed grep mkdir rm stat df cut tr head sleep date sha256sum od cmp dirname basename uname cat ls; do
  p=$(command -v "$t" 2>/dev/null) || continue
  ln -sf "$p" "$BASE/nodl/$t" 2>/dev/null
done
out=$(env PATH="$BASE/nodl" sh "$BASE/install.sh" plan 2>&1)
if [ -x /data/adb/magisk/busybox ]; then
  # Android：兜底应该能靠 Root 方案自带的 busybox 成功
  case "$out" in
    *"将安装 magpie 9.9.9"*) ok "没有 wget 时用 busybox 兜底成功" ;;
    *) bad "busybox 兜底没生效：$out" ;;
  esac
else
  # 桌面：没有 busybox 也没有 curl，应该给出可读的失败提示而不是静默
  case "$out" in
    *"下载器"*|*"取不到更新清单"*) ok "明确报告拿不到清单/没有下载器" ;;
    *) bad "失败信息不可读：$out" ;;
  esac
fi

step "17 收到 TERM：先释放锁再退出，不继续安装"
if command -v python3 >/dev/null 2>&1; then
  fresh
  # 一个只接受连接、从不应答的服务器：把清单下载卡住
  python3 -c 'import socket,time
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8898))
s.listen(1)
c, _ = s.accept()
time.sleep(120)' >/dev/null 2>&1 &
  HANG=$!
  sleep 0.5
  MAGPIE_MANIFEST_URL="http://127.0.0.1:8898/manifest.json" \
    sh "$BASE/install.sh" install --yes >/dev/null 2>&1 &
  INS=$!
  sleep 1.5
  kill -TERM "$INS" 2>/dev/null
  sleep 1.5
  if kill -0 "$INS" 2>/dev/null; then
    bad "收到 TERM 后仍在继续跑"
    kill -9 "$INS" 2>/dev/null
  else
    ok "收到 TERM 后立即退出"
  fi
  [ -d "$BASE/.install.lock" ] && bad "锁没释放，别的安装会同时进来" || ok "锁已释放"
  [ -f "$BASE/bin/magpie" ] && bad "终止后仍落了文件" || ok "没有落盘"
  kill -9 "$HANG" 2>/dev/null
else
  echo "  SKIP 没有 python3，跳过挂起服务器用例"
fi

rm -rf "$BASE"
echo
echo "结果： PASS $PASS ， FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
