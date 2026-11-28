#!/system/bin/sh
# magpie 命令行包装：补上 Android 上缺的环境变量后调用真正的二进制
#   HOME          数据目录（默认 / 只读，写配置会失败）
#   SSL_CERT_FILE 系统 CA 证书（静态 Go 找不到）
#   MAGPIE_BUN    Android 版 Bun（自带的 glibc 版跑不起来）
# 用法: magpie [参数...]

umask 077

# 数据目录跟着配置走：自定义 magpie_path 时，命令不能还指着默认目录。
# 查找顺序与 magpie.service / status.sh 一致（MAGPIE_CONF > 数据目录那份 > 模块自带默认）。
_self="$0"
while [ -L "$_self" ]; do
  _l=$(readlink "$_self" 2>/dev/null)
  case "$_l" in
    '') break ;;
    /*) _self="$_l" ;;
    *)  _self="$(dirname "$_self")/$_l" ;;
  esac
done
_SD=$(cd "$(dirname "$_self")" 2>/dev/null && pwd)
[ -n "$_SD" ] || _SD=/data/adb/magpie/scripts
[ -f "$_SD/lib.sh" ] && . "$_SD/lib.sh" 2>/dev/null


magpie_path=/data/adb/magpie
if command -v magpie_resolve_conf >/dev/null 2>&1; then
  _CONF=$(magpie_resolve_conf "$_SD/..") || _CONF=''
else
  _CONF=${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}
fi
if [ -f "$_CONF" ]; then
  if sh -n "$_CONF" >/dev/null 2>&1; then . "$_CONF"
  else echo "! 配置文件有语法错误，改用默认值：$_CONF" >&2; fi
fi
[ -n "${magpie_path:-}" ] || magpie_path=/data/adb/magpie

MAGPIE_DATA="$magpie_path/data"
REAL_BIN="$magpie_path/bin/magpie"

CA_BUNDLE="$MAGPIE_DATA/certs/ca-bundle.crt"
CA_STAMP="$CA_BUNDLE.stamp"

mkdir -p "$MAGPIE_DATA" 2>/dev/null
export HOME="$MAGPIE_DATA"
export MAGPIE_HOME="$MAGPIE_DATA"

# 证书包与 magpie.service 共用 lib.sh 里的实现：系统 CA 变了就重建。
# 指纹只取一次，比对和写 stamp 用同一个值 —— 两次取值之间目录 mtime 变了，
# 会写进一个永远匹配不上的 stamp，导致每次调用都白重建一遍。
if command -v magpie_ca_fingerprint >/dev/null 2>&1 \
   && command -v magpie_write_ca_bundle >/dev/null 2>&1; then
  _fp=$(magpie_ca_fingerprint)
  if [ ! -s "$CA_BUNDLE" ] || [ "$(cat "$CA_STAMP" 2>/dev/null)" != "$_fp" ]; then
    if _n=$(magpie_write_ca_bundle "$CA_BUNDLE" 2>/dev/null); then
      echo "$_fp" > "$CA_STAMP" 2>/dev/null
    fi
  fi
elif [ ! -s "$CA_BUNDLE" ]; then
  echo "提示：lib.sh 缺失，无法生成 CA 证书包，HTTPS 请求可能失败。" >&2
  echo "      重装模块可恢复：管理器点 [执行]，或刷入最新 zip。" >&2
fi
[ -s "$CA_BUNDLE" ] && export SSL_CERT_FILE="$CA_BUNDLE"

# Android 版 Bun（插件用）
for _b in "$MAGPIE_DATA"/.cache/magpie/bun/*/magpie-bun; do
  [ -x "$_b" ] && { export MAGPIE_BUN="$_b"; break; }
done

# 网关地址
# 配置中通常只是赋值而不是 export；实际运行的上游 CLI 也必须收到自定义端口。
export MAGPIE_ADDR="${MAGPIE_ADDR:-127.0.0.1:3425}"
export RES_OPTIONS="${RES_OPTIONS:-timeout:2 attempts:2}"
if [ ! -r /etc/resolv.conf ]; then
  echo "提示：/etc/resolv.conf 不存在，Go 解析器没有上游 DNS（原生通道会全部失败）。" >&2
  echo "      重启一次手机让模块覆盖生效；改 MAGPIE_DNS 见 README 的「配置」一节。" >&2
fi

# 本体不在时给一句能照着做的提示，而不是 shell 的 "not found"
if [ ! -x "$REAL_BIN" ]; then
  echo "找不到 magpie 本体：$REAL_BIN" >&2
  echo "装本体：管理器点 [执行]，或 sh /data/adb/modules/magpie/scripts/install.sh install --yes" >&2
  exit 127
fi

exec "$REAL_BIN" "$@"
