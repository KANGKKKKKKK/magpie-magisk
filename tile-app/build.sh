#!/bin/sh
# 构建磁贴 App：com.ruin.magpie.tile
#
#   sh tile-app/build.sh [输出目录]
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
OUT=${1:-"$HERE/build"}
ROOT=$(cd "$HERE/.." && pwd)

# ---- 工具链 ----
# SDK 位置：优先 ANDROID_SDK（本地可显式指定），其次 ANDROID_HOME（CI 常用），
# 最后才退回 /opt/android-sdk。写死一个路径会让 CI 上直接「找不到 build-tools」。
SDK=${ANDROID_SDK:-${ANDROID_HOME:-/opt/android-sdk}}
BT=$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)
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
KSPASS=${MAGPIE_KS_PASS:-}
KEYALIAS=${MAGPIE_KEY_ALIAS:-magpie}
if [ -z "$KS" ] || [ ! -f "$KS" ]; then
  echo "没有签名密钥：设 MAGPIE_KEYSTORE 指向 .jks 文件" >&2
  echo "（新生成一把见 tile-app/README.md，密钥不要提交到仓库）" >&2
  exit 1
fi
if [ -z "$KSPASS" ]; then
  echo "没有密钥口令：设 MAGPIE_KS_PASS" >&2
  exit 1
fi

WORK="$OUT/work"
rm -rf "$OUT"
mkdir -p "$WORK/gen" "$WORK/classes" "$WORK/dex" "$WORK/apk"

echo "→ 资源与 R.java"
aapt package -f -m -J "$WORK/gen" -M "$HERE/AndroidManifest.xml" \
  -S "$HERE/res" -I "$ANDROID_JAR"

echo "→ 编译"
# 用 -source/-target 8 而不是 --release：--release 会忽略 -bootclasspath，
# 那样 javac 会拿 JDK 自带的类去校验，Android 的类全找不到。
#
# 输出先落文件再过滤：直接 `javac ... | grep ...` 有两个坑：
#   1. 管道让 $? 变成 grep 的退出码，javac 失败会被当成成功（set -e 也不管用）；
#   2. 过滤规则写宽一点就把 error 也滤掉了。
# 曾经因此打出一个只有部分类的 APK，装上去一启动就 ClassNotFoundException。
javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" \
  $(find "$HERE/src" "$WORK/gen" -name '*.java') >"$WORK/javac.log" 2>&1
_javac_rc=$?
# 只滤掉 javac 关于 -source/-target 已过时的提示，其余原样打出来
grep -vE 'bootstrap class path|source value 8|target value 8|obsolete|Xlint' \
  "$WORK/javac.log" || true
if [ "$_javac_rc" -ne 0 ]; then
  echo "编译失败（javac 退出码 $_javac_rc）" >&2
  exit 1
fi

# 兜底自检：每个源文件都必须产出对应的 .class，防止「编译没报错但类没生成」
for _java in $(find "$HERE/src" -name '*.java'); do
  _cls="$WORK/classes/$(echo "${_java#"$HERE/src/"}" | sed 's/\.java$/.class/')"
  if [ ! -f "$_cls" ]; then
    echo "编译产物缺失：${_cls#"$WORK/classes/"}" >&2
    exit 1
  fi
done

echo "→ dex"
"$BT/d8" --min-api 29 --output "$WORK/dex" \
  $(find "$WORK/classes" -name '*.class') >"$WORK/d8.log" 2>&1
_d8_rc=$?
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
for _need in MagpieTileService MainActivity LauncherIcon Shell; do
  if ! grep -qa "$_need" "$WORK/dex/classes.dex"; then
    echo "dex 里缺少 $_need，拒绝产出 APK" >&2
    exit 1
  fi
done

echo "→ 打包"
aapt package -f -M "$HERE/AndroidManifest.xml" -S "$HERE/res" \
  -I "$ANDROID_JAR" -F "$WORK/base.apk"
( cd "$WORK/apk" && unzip -qo "$WORK/base.apk" && cp "$WORK/dex/classes.dex" . \
  && zip -qr "$WORK/unaligned.apk" . )

echo "→ 对齐"
zipalign -f 4 "$WORK/unaligned.apk" "$WORK/aligned.apk"

echo "→ 签名"
"$BT/apksigner" sign \
  --ks "$KS" --ks-key-alias "$KEYALIAS" \
  --ks-pass "pass:$KSPASS" --key-pass "pass:$KSPASS" \
  --out "$OUT/magpie-tile.apk" "$WORK/aligned.apk" 2>&1 \
  | grep -vE '^WARNING' || true

"$BT/apksigner" verify "$OUT/magpie-tile.apk" >/dev/null 2>&1 \
  || { echo "签名校验失败" >&2; exit 1; }

echo
echo "已生成 $OUT/magpie-tile.apk ($(stat -c %s "$OUT/magpie-tile.apk") 字节)"
