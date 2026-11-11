#!/system/bin/sh
# magpie 命令行包装：补上 Android 上缺的环境变量后调用真正的二进制
#   HOME          数据目录（默认 / 只读，写配置会失败）
#   SSL_CERT_FILE 系统 CA 证书（静态 Go 找不到）
#   MAGPIE_BUN    Android 版 Bun（自带的 glibc 版跑不起来）
# 用法: magpie [参数...]

MAGPIE_DATA=/data/adb/magpie/data
REAL_BIN=/data/adb/magpie/bin/magpie

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

# 上游 DNS：用 DNS_LOCAL_HOSTNAMES 直连公网，不占 53 端口（避免与热点冲突）
_mp_conf="/data/adb/magpie/scripts/magpie.config"
# shellcheck disable=SC1090
[ -f "$_mp_conf" ] && . "$_mp_conf" 2>/dev/null
export DNS_LOCAL_HOSTNAMES="${DNS_LOCAL_HOSTNAMES:-${MAGPIE_DNS:-223.5.5.5 119.29.29.29 8.8.8.8}}"
export RES_OPTIONS="${RES_OPTIONS:-timeout:2 attempts:2}"

exec "$REAL_BIN" "$@"
