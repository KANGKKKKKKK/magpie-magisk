#!/bin/sh
# JVM 公共入口：直接编译生产纯 Java 类，所有断言保留标准的「  PASS」行。
# 不调用 Android / su / 正在运行的服务；仅 Handler/Looper 使用同步内存替身。
# 每次编译最多 90 秒，每个测试进程最多 30 秒，超时再给 5 秒强制结束。
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="$ROOT/tile-app/src/com/ruin/magpie/tile"
for cmd in javac java timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "JVM 测试缺少 $cmd" >&2; exit 1; }
done
for name in TileState SelfCheck Shell SerialExecutor Fetch; do
  [ -f "$SRC/$name.java" ] || { echo "缺少生产类 $name.java，拒绝跳过 JVM 测试" >&2; exit 1; }
done
for name in ClassifyTest TileStateTest SelfCheckTest ShellTest SerialExecutorTest FetchTest; do
  [ -f "$HERE/jvm/$name.java" ] || { echo "缺少 $name.java，拒绝跳过 JVM 测试" >&2; exit 1; }
done
W=$(mktemp -d "${TMPDIR:-/tmp}/magpie-jvm.XXXXXX")
trap 'rm -rf "$W"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$W/stubs/android/os" "$W/classes"
cat > "$W/stubs/android/os/Looper.java" <<'JAVA'
package android.os;
public class Looper { public static Looper getMainLooper() { return new Looper(); } }
JAVA
cat > "$W/stubs/android/os/Handler.java" <<'JAVA'
package android.os;
public class Handler {
    public Handler(Looper looper) {}
    public boolean post(Runnable runnable) { runnable.run(); return true; }
}
JAVA
timeout -k 5 90 javac -encoding UTF-8 -d "$W/classes" \
  "$W"/stubs/android/os/*.java \
  "$SRC/TileState.java" "$SRC/SelfCheck.java" "$SRC/Shell.java" "$SRC/SerialExecutor.java" \
  "$SRC/Fetch.java" \
  "$HERE/jvm/ClassifyTest.java" "$HERE/jvm/TileStateTest.java" \
  "$HERE/jvm/SelfCheckTest.java" "$HERE/jvm/ShellTest.java" "$HERE/jvm/SerialExecutorTest.java" \
  "$HERE/jvm/FetchTest.java"
# FetchTest 的本地 HTTPS 服务器用一次性自签证书，只活在这个临时目录里。
command -v keytool >/dev/null 2>&1 || { echo "JVM 测试缺少 keytool" >&2; exit 1; }
FETCH_PASS=$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')
keytool -genkeypair -storetype PKCS12 -keystore "$W/fetch.p12" -alias local -keyalg RSA -keysize 2048 \
  -validity 1 -dname CN=127.0.0.1 -ext SAN=ip:127.0.0.1 \
  -storepass "$FETCH_PASS" -keypass "$FETCH_PASS" >/dev/null 2>&1
for name in ClassifyTest TileStateTest SelfCheckTest ShellTest SerialExecutorTest FetchTest; do
  echo "== jvm/$name"
  # 落文件后再读：管道不能掩盖 Java 非零退出/timeout，也不能按部分 PASS 报成功。
  if timeout -k 5 30 java -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 \
      -Dmagpie.ks="$W/fetch.p12" -Dmagpie.kspass="$FETCH_PASS" \
      -cp "$W/classes" "com.ruin.magpie.tile.$name" > "$W/$name.log" 2>&1; then
    cat "$W/$name.log"
  else
    rc=$?
    cat "$W/$name.log" >&2
    echo "$name 失败或超时（exit $rc）" >&2
    exit "$rc"
  fi
  if grep -qE '^  FAIL' "$W/$name.log" || ! grep -qE '^  PASS' "$W/$name.log"; then
    echo "$name 没有有效 PASS 或含 FAIL，拒绝仅按退出码报成功" >&2
    exit 1
  fi
done
