#!/bin/sh
# 构建磁贴 App：com.ruin.magpie.tile
#
#   sh tile-app/build.sh [--unsigned] [输出目录]
#
# 需要：
#   aapt / zipalign（aarch64 版，apt 装的）
#   javac（任意 JDK 8+）
#   d8 / apksigner（Android build-tools 里的 Java 程序，跨架构可用）
#   android.jar（compileSdk）
#
# 签名密钥默认读 $MAGPIE_KEYSTORE，密码读 $MAGPIE_KS_PASS。
# 两者都不进仓库：密钥丢了以后每个版本都要用户卸载重装。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
MODE=signed
if [ "${1:-}" = --unsigned ]; then MODE=unsigned; shift; fi
[ "$#" -le 1 ] || { echo "用法：sh tile-app/build.sh [--unsigned] [输出目录]" >&2; exit 1; }
OUT=${1:-"$HERE/build"}

# ---- 工具链 ----
# SDK 位置：优先 ANDROID_SDK（本地可显式指定），其次 ANDROID_HOME（CI 常用），
# 最后才退回 /opt/android-sdk。写死一个路径会让 CI 上直接「找不到 build-tools」。
SDK=${ANDROID_SDK:-${ANDROID_HOME:-/opt/android-sdk}}
BT=${MAGPIE_BUILD_TOOLS:-}
if [ -z "$BT" ]; then
  BT=$(
    for _bt in "$SDK"/build-tools/*; do
      [ -d "$_bt" ] && printf '%s\n' "$_bt"
    done | sort -V | tail -1
  )
fi
[ -n "$BT" ] || { echo "找不到 build-tools" >&2; exit 1; }
# 固定用 android-34，不取「最新」：SDK 里可能装着 android-37.0 这种
# preview 平台，它的 android.jar 没有完整属性表（连 android:exported 都查不到），
# 用它会让 aapt 报一堆 "No resource identifier found for attribute"。
ANDROID_JAR=${ANDROID_JAR:-}
if [ -z "$ANDROID_JAR" ]; then
  for c in 34 35 36; do
    [ -f "$SDK/platforms/android-$c/android.jar" ] && { ANDROID_JAR="$SDK/platforms/android-$c/android.jar"; break; }
  done
fi
[ -n "$ANDROID_JAR" ] || { echo "找不到可用的 android.jar（需要 android-34 这类正式平台）" >&2; exit 1; }

for c in aapt zipalign javac zip; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c" >&2; exit 1; }
done

# ---- 签名 ----
KS=${MAGPIE_KEYSTORE:-}
KEYALIAS=${MAGPIE_KEY_ALIAS:-magpie}
if [ "$MODE" = signed ]; then
  if [ -z "$KS" ] || [ ! -f "$KS" ]; then
    echo "没有签名密钥：设 MAGPIE_KEYSTORE 指向 .jks 文件" >&2
    exit 1
  fi
  [ -n "${MAGPIE_KS_PASS:-}" ] || { echo "没有签名口令：设 MAGPIE_KS_PASS" >&2; exit 1; }
  export MAGPIE_KS_PASS
fi

# 在私有临时目录构建，不删除调用方给出的输出目录或上次产物。
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "$OUT/.tile-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
mkdir -p "$WORK/gen" "$WORK/classes" "$WORK/dex" "$WORK/apk"

echo "→ 资源与 R.java"
aapt package -f -m -J "$WORK/gen" -M "$HERE/AndroidManifest.xml" \
  -S "$HERE/res" -I "$ANDROID_JAR"
[ -s "$WORK/gen/com/ruin/magpie/tile/R.java" ] || {
  echo "aapt 没有产出 com/ruin/magpie/tile/R.java" >&2
  exit 1
}

echo "→ 编译"
# 用 -source/-target 8 而不是 --release：--release 会忽略 -bootclasspath，
# 那样 javac 会拿 JDK 自带的类去校验，Android 的类全找不到。
#
# 输出先落文件再过滤：直接 `javac ... | grep ...` 有两个坑：
#   1. 管道让 $? 变成 grep 的退出码，javac 失败会被当成成功（set -e 也不管用）；
#   2. 过滤规则写宽一点就把 error 也滤掉了。
# 曾经因此打出一个只有部分类的 APK，装上去一启动就 ClassNotFoundException。
# 文件名由仓库控制；这里刻意把 find 结果拆成独立的 javac 参数。
# shellcheck disable=SC2046
if javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" \
  $(find "$HERE/src" "$WORK/gen" -name '*.java') >"$WORK/javac.log" 2>&1; then
  _javac_rc=0
else
  _javac_rc=$?
fi
# 只滤掉 javac 关于 -source/-target 已过时的提示，其余原样打出来
grep -vE 'bootstrap class path|source value 8|target value 8|obsolete|Xlint' \
  "$WORK/javac.log" || true
if [ "$_javac_rc" -ne 0 ]; then
  echo "编译失败（javac 退出码 $_javac_rc）" >&2
  exit 1
fi

# 兜底自检：每个源文件都必须产出对应的 .class，防止「编译没报错但类没生成」
# 仓库 Java 源文件名不含空白；与上面的显式参数列表采用相同约定。
# shellcheck disable=SC2044
for _java in $(find "$HERE/src" -name '*.java'); do
  _cls="$WORK/classes/$(echo "${_java#"$HERE/src/"}" | sed 's/\.java$/.class/')"
  if [ ! -f "$_cls" ]; then
    echo "编译产物缺失：${_cls#"$WORK/classes/"}" >&2
    exit 1
  fi
done

echo "→ dex"
# 同上：受控 .class 路径需要拆成独立参数，不是单个带换行的参数。
# shellcheck disable=SC2046
if "$BT/d8" --release --min-api 29 --output "$WORK/dex" \
  $(find "$WORK/classes" -name '*.class') >"$WORK/d8.log" 2>&1; then
  _d8_rc=0
else
  _d8_rc=$?
fi
grep -vE '^Warning' "$WORK/d8.log" || true
if [ "$_d8_rc" -ne 0 ]; then
  echo "dex 生成失败（d8 退出码 $_d8_rc）" >&2
  exit 1
fi
[ -s "$WORK/dex/classes.dex" ] || { echo "d8 没有产出 classes.dex" >&2; exit 1; }

# 关键自检：dex 里必须能找到这些类。
# 少了任何一个，装上去就是 ClassNotFoundException / NoClassDefFoundError 闪退。
# 这份清单要与 .github/workflows/ci.yml 里的一致 —— 漏掉一个类时
# 编译能过、dex 也在，问题要到运行时才炸。
for _need in MagpieTileService MainActivity LauncherIcon Shell SelfCheck TileState SerialExecutor Fetch; do
  # 匹配完整类描述符，不用子串：「Shell」也是别的类名的一部分。
  if ! grep -qa "Lcom/ruin/magpie/tile/$_need;" "$WORK/dex/classes.dex"; then
    echo "dex 里缺少 $_need，拒绝产出 APK" >&2
    exit 1
  fi
done

echo "→ 打包"
aapt package -f -M "$HERE/AndroidManifest.xml" -S "$HERE/res" \
  -I "$ANDROID_JAR" -F "$WORK/base.apk"
( cd "$WORK/apk" && unzip -qo "$WORK/base.apk" && cp "$WORK/dex/classes.dex" . \
  && zip -qr -n .arsc:.png "$WORK/unaligned.apk" . )
# targetSdk >= 30 要求 resources.arsc 不压缩（AOSP 否则拒装：RESOURCES_ARSC_COMPRESSED）。

echo "→ 对齐"
zipalign -f 4 "$WORK/unaligned.apk" "$WORK/aligned.apk"
if [ "$MODE" = unsigned ]; then
  mv -f "$WORK/aligned.apk" "$OUT/magpie-tile-unsigned.apk"
  printf '已生成未签名磁贴：%s/magpie-tile-unsigned.apk\n' "$OUT"
  exit 0
fi

echo "→ 签名"
# 先独立保存 sign 的退出码，再过滤日志；即使旧/部分 APK 能 verify 也不能掩盖 sign 失败。
if "$BT/apksigner" sign \
  --ks "$KS" --ks-key-alias "$KEYALIAS" \
  --ks-pass env:MAGPIE_KS_PASS --key-pass env:MAGPIE_KS_PASS \
  --out "$WORK/signed.apk" "$WORK/aligned.apk" >"$WORK/sign.log" 2>&1; then
  _sign_rc=0
else
  _sign_rc=$?
fi
grep -vE '^WARNING' "$WORK/sign.log" || true
if [ "$_sign_rc" -ne 0 ]; then
  echo "签名失败（apksigner sign 退出码 $_sign_rc）" >&2
  exit 1
fi

"$BT/apksigner" verify "$WORK/signed.apk" >/dev/null 2>&1 \
  || { echo "签名校验失败" >&2; exit 1; }

mv -f "$WORK/signed.apk" "$OUT/magpie-tile.apk"
echo "已生成 $OUT/magpie-tile.apk ($(stat -c %s "$OUT/magpie-tile.apk") 字节)"
