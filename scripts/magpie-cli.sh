#!/system/bin/sh
# magpie 命令行包装：补上 Android 上缺的环境变量后调用真正的二进制
#   HOME          数据目录（默认 / 只读，写配置会失败）
#   SSL_CERT_FILE 系统 CA 证书（静态 Go 找不到）
#   MAGPIE_BUN    Android 版 Bun（自带的 glibc 版跑不起来）
# 用法: magpie [参数...]

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
command -v magpie_resolve_conf >/dev/null 2>&1 || magpie_resolve_conf() { return 1; }

magpie_path=/data/adb/magpie
_CONF=$(magpie_resolve_conf "$_SD/.." 2>/dev/null)
[ -n "$_CONF" ] && . "$_CONF" 2>/dev/null
[ -n "${magpie_path:-}" ] || magpie_path=/data/adb/magpie

MAGPIE_DATA="$magpie_path/data"
REAL_BIN="$magpie_path/bin/magpie"

CA_BUNDLE="$MAGPIE_DATA/certs/ca-bundle.crt"
CA_STAMP="$CA_BUNDLE.stamp"
CA_DIRS="/system/etc/security/cacerts /apex/com.android.conscrypt/cacerts"

mkdir -p "$MAGPIE_DATA" 2>/dev/null
export HOME="$MAGPIE_DATA"
export MAGPIE_HOME="$MAGPIE_DATA"

# 证书包与 magpie.service 用同一份指纹，系统 CA 变了就重建
ca_fingerprint() {
  _fp=""
  for _d in $CA_DIRS; do
    if [ -d "$_d" ]; then
      _n=$(ls -1 "$_d" 2>/dev/null | wc -l | tr -d ' ')
      _t=$(stat -c %Y "$_d" 2>/dev/null)
      _fp="$_fp ${_d##*/}=${_n}/${_t:-0}"
    else
      _fp="$_fp ${_d##*/}=0/0"
    fi
  done
  echo "$_fp"
}

if [ ! -s "$CA_BUNDLE" ] || [ "$(cat "$CA_STAMP" 2>/dev/null)" != "$(ca_fingerprint)" ]; then
  _fp=$(ca_fingerprint)
  mkdir -p "$MAGPIE_DATA/certs" 2>/dev/null
  _tmp="$CA_BUNDLE.tmp"
  : > "$_tmp" 2>/dev/null
  _seen=""
  for _d in $CA_DIRS; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*.0; do
      [ -f "$_f" ] || continue
      case " $_seen " in *" ${_f##*/} "*) continue ;; esac
      _seen="$_seen ${_f##*/}"
      cat "$_f" >> "$_tmp" 2>/dev/null
    done
  done
  if [ -s "$_tmp" ] && grep -q 'BEGIN CERTIFICATE' "$_tmp" 2>/dev/null; then
    chmod 600 "$_tmp" 2>/dev/null
    mv -f "$_tmp" "$CA_BUNDLE" 2>/dev/null
    echo "$_fp" > "$CA_STAMP" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
fi
[ -s "$CA_BUNDLE" ] && export SSL_CERT_FILE="$CA_BUNDLE"

# Android 版 Bun（插件用）
for _b in "$MAGPIE_DATA"/.cache/magpie/bun/*/magpie-bun; do
  [ -x "$_b" ] && { export MAGPIE_BUN="$_b"; break; }
done

# 网关地址
[ -n "$MAGPIE_ADDR" ] || export MAGPIE_ADDR="127.0.0.1:3425"

# 上游 DNS：magpie 本体是静态编译的 Go 程序，只能读 /etc/resolv.conf。
# 模块用 Magisk 覆盖提供 /etc/resolv.conf，内容由 magpie.service 按 MAGPIE_DNS 重写，
# 所以改完这里重启服务即可（首次装上新版要重启一次手机才会出现覆盖文件）。
_mp_conf="/data/adb/magpie/scripts/magpie.config"
# shellcheck disable=SC1090
[ -f "$_mp_conf" ] && . "$_mp_conf" 2>/dev/null
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
