#!/system/bin/sh
# Magpie for Android - 本体安装器
# 检测 / 下载 / 校验 / 部署 magpie 本体（模块本身不含本体）
#
# 用法:
#   sh install.sh status                 只检测，输出一行机器可读状态
#   sh install.sh check                  联网查询可用版本，不下载
#   sh install.sh plan                   打印将要安装的版本/来源/大小
#   sh install.sh install [--yes]        下载并安装
#   sh install.sh rollback               用备份回退
#
# 设计要点:
#   - 只负责「首次安装」。已装好的升级交给 magpie 自己的 `magpie update`，
#     它有 mirror / channel / proxy，用的是厂商自己的校验，模块不重复实现。
#   - 已存在可用本体时绝不自动覆盖，必须显式 install（或加 --yes）。
#   - 只写 <magpie_path>/bin/magpie，不碰 data/、配置、账号、provider、密钥。
#   - 下载到同文件系统的临时文件，校验通过后原子替换，替换前留备份。
#   - 无终端可交互：确认靠「再点一次 [执行]」，见 cmd_install。

umask 022

# 把各 Root 方案自带的 busybox 放进 PATH。
# 实测：模块脚本被管理器/服务拉起时，PATH 可能只有系统目录，那里没有
# wget、awk、sed、stat、sha256sum —— 下载和校验会全部失败。
# magpie.service 早就这么做了，安装器同样需要。
export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/magpie

# 公共实现：路径归一化与白名单判断（check_target 要用）。
# 以前这里只有一句「判断逻辑在 lib.sh」的注释，但从来没 source 过 ——
# 于是 `command -v magpie_norm_path` 永远为假，归一化分支被静默跳过，
# 安装器又退回到原来那个 case。
if [ -f "$MODDIR/scripts/lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$MODDIR/scripts/lib.sh"
fi

CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
magpie_path=/data/adb/magpie
# 语法错误的配置不 source：BusyBox ash 会因此整个退出（见 lib.sh magpie_conf_syntax_ok）
if [ -f "$CONF" ] && ! sh -n "$CONF" >/dev/null 2>&1; then
  echo "! 配置文件有语法错误，已改用默认值：$CONF" >&2
else
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null
fi

BIN_DIR="$magpie_path/bin"
BIN="$BIN_DIR/magpie"
BAK="$BIN_DIR/magpie.bak"
INFO="$magpie_path/install-info.txt"
LOCK="$magpie_path/.install.flock"
PENDING="$magpie_path/.install.pending"

# 清单地址：厂商自己的更新端点，与 magpie 本体 `magpie update` 用的是同一个。
# 里面同时给出下载地址、大小和 sha256。可用环境变量指向自建镜像。
MANIFEST_URL="${MAGPIE_MANIFEST_URL:-https://usemagpie.ai/api/latest}"
# 只取这一个资产名。实测这是发布页里唯一的 Android 构建（没有 arm32 的）。
ASSET_KEY="${MAGPIE_ASSET_KEY:-magpie-cli-android-arm64}"
# 二次确认窗口（秒）：第一次点按只打印方案，窗口内再点一次才真正下载
CONFIRM_WINDOW="${MAGPIE_CONFIRM_WINDOW:-600}"

say()  { echo "$1"; }
warn() { echo "! $1"; }
die()  { echo "✗ $1" >&2; exit 1; }

# ---------- JSON 解析 ----------
# 清单可能是压缩的，也可能是带缩进的。先做一份「只压掉字符串外空白」的副本，
# 之后所有取值都在这份上做，正则就不必迁就空格。

minify_json() {
  awk '
    {
      out = ""; instr = 0; esc = 0
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (instr) {
          out = out c
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { instr = 0 }
        } else {
          if (c == "\"") { instr = 1; out = out c }
          else if (c == " " || c == "\t" || c == "\r") { }
          else { out = out c }
        }
      }
      print out
    }' "$1" | tr -d '\n'
}

# 首个 "key":"value" 里的 value。从 stdin 读
str_field() {
  awk -v k="\"$1\":\"" '
    { i = index($0, k); if (i == 0) next
      t = substr($0, i + length(k))
      n = index(t, "\""); if (n > 0) { print substr(t, 1, n - 1); exit } }'
}

# 首个 "key":123 里的数字。从 stdin 读
num_field() {
  awk -v k="\"$1\":" '
    { i = index($0, k); if (i == 0) next
      t = substr($0, i + length(k))
      if (match(t, /^[0-9]+([,}]|$)/)) { value = substr(t, 1, RLENGTH); sub(/[,}]$/, "", value); print value; exit } }'
}

# 从压缩后的清单里切出目标资产的那一段对象
extract_asset() {
  awk -v k="\"$ASSET_KEY\":" '
    {
      i = index($0, k)
      if (i == 0) next
      rest = substr($0, i + length(k))
      depth = 0; out = ""
      for (c = 1; c <= length(rest); c++) {
        ch = substr(rest, c, 1)
        if (ch == "{") { depth++ }
        else if (ch == "}") { depth--; if (depth == 0) break }
        else if (depth == 1) { out = out ch }
      }
      print out
    }' "$1" | head -1
}

# ---------- 下载器 ----------
# 只用会校验证书、并能把跳转限制在 HTTPS 的下载器：
#   1. curl（PATH 里的，或 MAGPIE_DL 指定的绝对路径）
#   2. 没有 curl 时，用系统自带的 Java TLS 栈：app_process 直接运行模块里磁贴 APK
#      中的 Fetch 类（Conscrypt + 系统 CA，不需要安装 App）。原版 Android 不带 curl，
#      以前这类设备的 [执行] 首次安装必然失败，还会被误报成「检查网络」。
# BusyBox wget 不在候选里：Magisk 自带的那份实测不校验证书。
DL_SCHEME=https
DL_CMD=''
DL_KIND=''
DL_STALL=${MAGPIE_DL_STALL:-60}
DL_TOTAL=${MAGPIE_DL_TIMEOUT:-1800}
DL_APK="${MAGPIE_FETCH_APK:-$MODDIR/magpie-tile.apk}"

pick_downloader() {
  [ -n "$DL_CMD" ] && return 0
  if [ -n "${MAGPIE_DL:-}" ]; then
    case "$MAGPIE_DL" in /*) [ -f "$MAGPIE_DL" ] && [ -x "$MAGPIE_DL" ] || return 1 ;; *) return 1 ;; esac
    DL_CMD=$MAGPIE_DL; DL_KIND=curl
  elif DL_CMD=$(command -v curl 2>/dev/null) && [ -n "$DL_CMD" ]; then
    DL_KIND=curl
  elif [ "${MAGPIE_DL_NO_JAVA:-0}" != 1 ] && [ -f "$DL_APK" ] && [ ! -L "$DL_APK" ] &&
       DL_CMD=$(command -v app_process 2>/dev/null) && [ -n "$DL_CMD" ]; then
    DL_KIND=java
  else
    DL_CMD=''; DL_KIND=''
    return 1
  fi
}

valid_download_url() (
  case "$1" in "$DL_SCHEME"://*) ;; *) exit 1 ;; esac
  _du_rest=${1#*://}
  _du_authority=${_du_rest%%[/?#]*}
  case "$_du_authority" in ''|*@*|*\\*) exit 1 ;; esac
  case "$1" in *[[:space:][:cntrl:]]*|*\\*) exit 1 ;; esac
)

dl_fetch() {
  _dl_url=$1; _dl_out=$2; _dl_limit=$3
  valid_download_url "$_dl_url" || return 1
  pick_downloader || return 127
  # -q 必须是第一项，忽略 curlrc 中的 insecure、代理或跳转选项。
  # 自定义 CA 仅由设备管理员显式选用；不接受清单提供的证书。
  set -- -q --fail --silent --show-error --location --max-redirs 5 \
    --proto "=$DL_SCHEME" --proto-redir "=$DL_SCHEME" --tlsv1.2 \
    --connect-timeout "$DL_STALL" --speed-limit 1024 --speed-time "$DL_STALL" \
    --max-time "$DL_TOTAL" --max-filesize "$_dl_limit"
  if [ "$DL_KIND" = curl ] && [ -n "${MAGPIE_TLS_CA_BUNDLE:-}" ]; then
    set -- "$@" --cacert "$MAGPIE_TLS_CA_BUNDLE"
  fi
  CHILD_STARTING=1
  if [ "$DL_KIND" = java ]; then
    # 参数与上面的 curl 约束一一对应；MAGPIE_TLS_CA_BUNDLE 只对 curl 生效。
    (exec 8>&-; CLASSPATH="$DL_APK" exec "$DL_CMD" / com.ruin.magpie.tile.Fetch \
      "$_dl_url" "$_dl_out" "$_dl_limit" "$DL_STALL" "$DL_TOTAL") 2>/dev/null &
  else
    (exec 8>&-; exec "$DL_CMD" "$@" -o "$_dl_out" -- "$_dl_url") 2>/dev/null &
  fi
  DL_PID=$!
  child_registered
  wait "$DL_PID"
  _dl_rc=$?
  DL_PID=''
  # 不回显可能含签名 URL 的下载器原始错误；保留可采取行动的分类和真实退出码。
  if [ "$_dl_rc" -ne 0 ]; then
    case "$DL_KIND:$_dl_rc" in
      curl:28|java:6) _dl_reason='下载超时' ;;
      curl:22|curl:47|java:4) _dl_reason='HTTP 响应或重定向失败' ;;
      curl:63|java:5) _dl_reason='下载超过大小上限' ;;
      curl:60)        _dl_reason='TLS 证书校验失败' ;;
      *)              _dl_reason='下载器失败' ;;
    esac
    warn "$_dl_reason（$DL_KIND 退出码 $_dl_rc）" >&2
  fi
  return "$_dl_rc"
}

dl_name() {
  if pick_downloader; then
    case "$DL_KIND" in java) printf '%s\n' "系统 Java TLS（app_process，经 $DL_APK）" ;; *) printf '%s\n' "$DL_CMD" ;; esac
  else
    printf '%s\n' '无可用的 HTTPS 下载器（没有 curl，且模块里的 magpie-tile.apk 或 app_process 不可用）'
  fi
}

valid_download_seconds() {
  # Java 的连接/读取超时使用有符号 int 毫秒；curl 的 0 则会关闭时限。
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 7 ] && [ "$1" -ge 1 ] && [ "$1" -le 2147483 ]
}

# 下载前先说清楚是「没有下载器」还是「网络问题」，两者的处理完全不同。
need_downloader() {
  if ! valid_download_seconds "$DL_STALL" || ! valid_download_seconds "$DL_TOTAL"; then
    warn "MAGPIE_DL_STALL 和 MAGPIE_DL_TIMEOUT 必须是 1 至 2147483 的整数秒"; return 1
  fi
  if pick_downloader; then
    if [ "$DL_KIND" = curl ] && [ -n "${MAGPIE_TLS_CA_BUNDLE:-}" ] &&
       { [ ! -f "$MAGPIE_TLS_CA_BUNDLE" ] || [ ! -r "$MAGPIE_TLS_CA_BUNDLE" ]; }; then
      warn "无法读取 MAGPIE_TLS_CA_BUNDLE 指定的 CA 文件"; return 1
    fi
    return 0
  fi
  say "✗ 没有能校验证书的 HTTPS 下载器"
  say "  · 重刷完整的模块 zip（里面的 magpie-tile.apk 提供下载能力，不必安装它）"
  say "  · 或装一个 curl（如 Termux），再用 MAGPIE_DL=/绝对路径/curl 指定"
  return 1
}

# 下载大文件时每 10 秒报一次进度：Magisk 的文本框几分钟没输出，用户会以为卡死而退出。
progress_start() {
  _pg_file=$1; _pg_total=$2
  [ -n "$_pg_total" ] && [ "$_pg_total" -gt 4194304 ] 2>/dev/null || return 0
  _pg_parent=$$
  CHILD_STARTING=1
  (
    exec 8>&-
    _pg_timer=''; CHILD_STARTING=''; CHILD_SIGNAL=''
    trap 'stop_child "$_pg_timer"' EXIT
    trap 'on_signal 0' INT TERM HUP
    while :; do
      # wait 可以被 trap 打断；前台 sleep 会让每次完成/取消都可能多等十秒。
      CHILD_STARTING=1
      sleep 10 &
      _pg_timer=$!
      child_registered
      wait "$_pg_timer" || break
      _pg_timer=''
      kill -0 "$_pg_parent" 2>/dev/null || break
      _pg_now=$(stat -c %s "$_pg_file" 2>/dev/null) || _pg_now=0
      say "  … 已下载 $(human_size "$_pg_now") / $(human_size "$_pg_total")（$((_pg_now * 100 / _pg_total))%）"
    done
  ) &
  PROGRESS_PID=$!
  child_registered
}
progress_stop() {
  stop_child "$PROGRESS_PID"
  PROGRESS_PID=''
}

fetch_manifest() {
  # $1 = 输出文件（压缩后的版本）
  _raw="$1.raw"
  rm -f "$1" "$_raw" 2>/dev/null

  # 清单很小，但同样容许一次抖动
  _ok=0
  for _try in 1 2; do
    [ "$_try" = "2" ] && sleep 2
    if dl_fetch "$MANIFEST_URL" "$_raw" 1048576 && [ -s "$_raw" ] && [ "$(wc -c < "$_raw")" -le 1048576 ]; then
      _ok=1
      break
    fi
  done
  if [ "$_ok" != "1" ]; then
    rm -f "$_raw" 2>/dev/null
    say "  （下载器：$(dl_name)）"
    return 1
  fi

  minify_json "$_raw" > "$1" 2>/dev/null
  rm -f "$_raw" 2>/dev/null
  [ -s "$1" ] || return 1
  # 必须像 magpie 的清单，否则可能是错误页或被替换的内容
  grep -q '"version"' "$1" 2>/dev/null || return 1
  grep -q "\"$ASSET_KEY\"" "$1" 2>/dev/null || return 1
  return 0
}

# ---------- 状态检测 ----------

# 把二进制跑起来问版本，带超时；成功则打印版本号
probe_version() (
  [ -f "$1" ] && [ -x "$1" ] || exit 1
  _pv_out=$(HOME="$magpie_path/data" MAGPIE_HOME="$magpie_path/data" \
    timeout 60 "$1" --version 2>/dev/null) || exit 1
  _pv_first=${_pv_out%%'
'*}
  case "$_pv_first" in
    'magpie '?*) printf '%s\n' "${_pv_first#magpie }" ;;
    *) exit 1 ;;
  esac
)

# 状态和显示的版本必须来自同一次 --version；不同路径的部署自检仍分别执行。
inspect_bin() {
  BIN_VERSION=''
  if [ ! -e "$BIN" ]; then
    BIN_STATE=missing
  elif BIN_VERSION=$(probe_version "$BIN"); then
    BIN_STATE=ready
  else
    BIN_STATE=broken
  fi
}

# ---------- 环境检查 ----------

check_arch() {
  # MAGPIE_ALLOW_ANY_ARCH=1 只给测试用：CI 跑在 x86_64 上，
  # 不放行的话整套安装器用例都会被这道闸门挡住。
  [ "${MAGPIE_ALLOW_ANY_ARCH:-0}" = "1" ] && return 0
  _m=$(uname -m 2>/dev/null)
  case "$_m" in
    aarch64|arm64) return 0 ;;
    *) return 1 ;;
  esac
}

human_size() {
  _n="$1"
  [ -n "$_n" ] || { echo "未知"; return; }
  if [ "$_n" -ge 1048576 ] 2>/dev/null; then
    echo "$((_n / 1048576)) MB"
  elif [ "$_n" -ge 1024 ] 2>/dev/null; then
    echo "$((_n / 1024)) KB"
  else
    echo "$_n B"
  fi
}

check_target() {
  # 先归一化：写成 "/data/" 时 case 匹配不上 "/data"，会漏过去。
  # 写入只允许持久数据目录；旧模块内布局仅允许 status 检查，便于停服迁移。
  # lib.sh 缺失时不能「跳过检查就当通过」—— 那等于回到修之前的状态，
  # 而且用户完全看不出来。这种情况直接拒绝，并说明原因。
  if ! command -v magpie_norm_path >/dev/null 2>&1 ||
     ! command -v magpie_path_installable >/dev/null 2>&1; then
    die "缺少 scripts/lib.sh，无法校验 magpie_path（重装模块可恢复）"
  fi
  _norm=$(magpie_norm_path "$magpie_path" 2>/dev/null) || \
    die "magpie_path 必须是绝对路径：$magpie_path"
  if [ "$_norm" != "$magpie_path" ]; then
    # 归一化会解析 . / .. 与重复斜杠，所以差异不一定是「多写了斜杠」。
    # 报错时直接把解析结果给出来，别让用户猜。
    die "magpie_path 不是规范路径：$magpie_path（解析后是 $_norm，请直接写这个）"
  fi
  if ! magpie_path_installable "$magpie_path"; then
    if magpie_path_in_module_tree "$magpie_path" "${MODDIR:-/data/adb/modules/magpie}"; then
      if [ "${1:-}" != status ] || ! magpie_path_cleanable "$magpie_path"; then
        die "拒绝把本体安装到 $magpie_path：模块更新或移除可能清掉其中的数据，请先备份并迁移到 /data/adb/magpie"
      fi
    else
      die "拒绝把本体安装到 $magpie_path（只允许 /data/adb/magpie 及其子目录）"
    fi
  fi
  # 逐级上溯，不允许路径里有符号链接指向别处
  _d="$magpie_path"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -L "$_d" ]; then
      die "$_d 是符号链接，出于安全考虑不接受"
    fi
    _d=$(dirname "$_d")
  done
  # 已有的子路径也不能是链接：否则 bin 指到别处仍会越过目录白名单，
  # 清单临时文件、备份或记录文件的重定向也可能跟随链接写到外面。
  for _target in "$BIN_DIR" "$BIN" "$BAK" "$INFO" "$LOCK" "$magpie_path/.install.lock" "$PENDING" \
                 "$magpie_path/.manifest.tmp" "$BIN.rejected"; do
    [ ! -L "$_target" ] || die "$_target 是符号链接，出于安全考虑不接受"
  done
  for _target in "$BIN" "$BAK" "$INFO" "$BIN.rejected"; do
    [ ! -e "$_target" ] || [ -f "$_target" ] || die "$_target 不是普通文件"
  done
  return 0
}

check_space() {
  _need="$1"
  [ -n "$_need" ] || _need=104857600
  # 同时要放临时文件和备份，按两倍再加 50MB 余量
  _want=$((_need * 2 + 52428800))
  _free=$(df -Pk "$magpie_path" 2>/dev/null | tail -1 | awk '{print $4}')
  case "$_free" in
    ''|*[!0-9]*) return 0 ;;   # 取不到就不拦
  esac
  _free=$((_free * 1024))
  if [ "$_free" -lt "$_want" ]; then
    die "空间不足：需要约 $(human_size "$_want")，可用 $(human_size "$_free")"
  fi
  return 0
}

# ---------- 锁定 ----------

# 旧 .install.lock 目录只作诊断信息，不再读取 owner 或自动回收。
# 8 号 FD 始终由 cleanup_install 无条件解锁并关闭，无 HELD 标志窗口。
acquire_lock() {
  if ! command -v magpie_pick_flock >/dev/null 2>&1 || ! magpie_pick_flock; then
    die "缺少可用的 flock，拒绝不安全地安装（请恢复 Root BusyBox / lib.sh）"
  fi
  mkdir -p "$magpie_path" 2>/dev/null || die "无法创建 $magpie_path"
  if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && [ ! -f "$LOCK" ]; }; then
    die "安装锁不是普通文件或是符号链接：$LOCK"
  fi
  exec 8>>"$LOCK"
  # shellcheck disable=SC3013  # Android ash/mksh 与 Linux dash 均支持 inode 比较
  if [ -L "$LOCK" ] || [ ! "$LOCK" -ef /proc/self/fd/8 ]; then
    die "安装锁路径已改变：$LOCK"
  fi
  # 安装采用非阻塞锁，重复点击立即给出可读错误；不依赖 BusyBox 的 -w。
  magpie_flock -n 8 || die "另一个安装正在进行，或内核 flock 不可用，请稍后重试"
}

release_lock() {
  magpie_flock -u 8 2>/dev/null || :
  exec 8>&-
}

DL_PID=''; PROGRESS_PID=''; DOWNLOAD_TMP=''
CHILD_STARTING=''; CHILD_SIGNAL=''

stop_child() {
  [ -n "$1" ] || return 0
  kill -TERM "$1" 2>/dev/null || :
  wait "$1" 2>/dev/null || :
}

cleanup_install() {
  trap '' INT TERM HUP
  stop_child "$DL_PID"
  progress_stop
  [ -z "$DOWNLOAD_TMP" ] || rm -f "$DOWNLOAD_TMP" 2>/dev/null
  clear_manifest_tmp
  finish_swap || :
  release_lock
}

on_signal() {
  # spawn 与记录 $! 之间信号先记账，以免留下没有 PID 可回收的子进程。
  if [ -n "$CHILD_STARTING" ]; then CHILD_SIGNAL="$1"; return; fi
  trap '' INT TERM HUP
  exit "$1"
}

child_registered() {
  CHILD_STARTING=''
  [ -z "$CHILD_SIGNAL" ] || on_signal "$CHILD_SIGNAL"
}

# ---------- 下载 ----------

download_verified() {
  _tmp="$1"; _want_size="$2"; _want_sum="$3"; shift 3
  # 来源按顺序试一轮；一轮全失败再试一轮（有限重试，避免网络抖动）
  _pass=1
  while [ "$_pass" -le 2 ]; do
    if [ "$_pass" = "2" ]; then
      warn "第一轮来源都失败了，稍后重试一轮"
      sleep 3
    fi
    for _u in "$@"; do
      [ -n "$_u" ] || continue
      say "  下载 $_u"
      say "  （约 $(human_size "$_want_size")，视网络可能要几分钟）"
      : > "$_tmp" || return 1
      progress_start "$_tmp" "$_want_size"
      if ! dl_fetch "$_u" "$_tmp" "$_want_size"; then
        progress_stop
        warn "下载失败，换下一个来源"
        continue
      fi
      progress_stop
      [ -s "$_tmp" ] || { warn "下到空文件"; continue; }

      if [ -n "$_want_size" ]; then
        _got=$(stat -c %s "$_tmp" 2>/dev/null)
        if [ "$_got" != "$_want_size" ]; then
          warn "大小不符（期望 $_want_size，实际 $_got），丢弃"
          continue
        fi
      fi

      # 拒绝把 HTML 错误页当成二进制
      if head -c 15 "$_tmp" 2>/dev/null | grep -q '<'; then
        warn "下载内容像网页而不是二进制，丢弃"
        continue
      fi

      if [ -n "$_want_sum" ]; then
        say "  校验 sha256 ..."
        _got_sum=$(sha256sum "$_tmp" 2>/dev/null | awk '{print $1}')
        if [ "$_got_sum" != "$_want_sum" ]; then
          warn "sha256 不匹配，丢弃"
          warn "  期望 $_want_sum"
          warn "  实际 $_got_sum"
          continue
        fi
        say "  ✓ sha256 一致"
      fi
      return 0
    done
    _pass=$((_pass + 1))
  done
  return 1
}

# ---------- 部署（全程持安装锁） ----------

SWAP_DIR=''
SWAP_PENDING=0
SWAP_INFO_TMP=''
SWAP_INFO_TOUCHED=0

# 硬链接保留原 inode、模式和上下文；正式位置不可用时原子放回，而不是盲目回旧 .bak。
restore_swap_file() {
  if [ -f "$1" ]; then
    # shellcheck disable=SC3013  # Android ash/mksh 与 Linux dash 支持 inode 比较
    [ "$1" -ef "$2" ] || mv -f "$1" "$2"
  else
    [ ! -e "$2" ] || rm -f "$2"
  fi
}

finish_swap() {
  [ -n "$SWAP_DIR" ] || return 0
  if [ "$SWAP_PENDING" = 1 ]; then
    if ! restore_swap_file "$SWAP_DIR/previous" "$BIN" ||
       { [ "$SWAP_INFO_TOUCHED" = 1 ] && ! restore_swap_file "$SWAP_DIR/previous-info" "$INFO"; }; then
      warn "未能恢复切换前的文件，保留救援目录：$SWAP_DIR" >&2
      return 1
    fi
  fi
  [ -z "$SWAP_INFO_TMP" ] || rm -f "$SWAP_INFO_TMP" 2>/dev/null
  rm -f "$SWAP_DIR/previous" "$SWAP_DIR/previous-info" "$SWAP_DIR/candidate" 2>/dev/null
  rmdir "$SWAP_DIR" 2>/dev/null || :
  SWAP_DIR=''; SWAP_INFO_TMP=''; SWAP_PENDING=0; SWAP_INFO_TOUCHED=0
}

begin_swap() {
  SWAP_DIR=$(mktemp -d "$BIN_DIR/.magpie.swap.XXXXXX") || die "无法创建私有切换目录"
  if [ -f "$BIN" ]; then
    ln "$BIN" "$SWAP_DIR/previous" 2>/dev/null || die "无法保留当前本体，未切换"
  fi
  if [ -f "$INFO" ]; then
    ln "$INFO" "$SWAP_DIR/previous-info" 2>/dev/null || die "无法保留当前安装信息，未切换"
  fi
}

publish_install_info() {
  SWAP_INFO_TMP=$(mktemp "$magpie_path/.install-info.XXXXXX") || return 1
  _info_time=$(date +'%Y-%m-%d %H:%M:%S') || return 1
  printf 'version=%s\ninstalled=%s\nsource=%s\nsha256=%s\nasset=%s\n' \
    "$1" "$_info_time" "$2" "$3" "$ASSET_KEY" > "$SWAP_INFO_TMP" 2>/dev/null || return 1
  chmod 600 "$SWAP_INFO_TMP" 2>/dev/null || return 1
  SWAP_INFO_TOUCHED=1
  mv -f "$SWAP_INFO_TMP" "$INFO"
}

switch_verified_binary() {
  # 所有权限与暂存自检已经完成；从这里起，失败或正常可捕获的中断由 EXIT 恢复原文件。
  SWAP_PENDING=1
  mv -f "$1" "$BIN" 2>/dev/null || die "原子替换失败，取消切换"
  if ! _sw_version=$(probe_version "$BIN") || [ "$_sw_version" != "$2" ]; then
    if finish_swap; then die "正式路径自检失败，已恢复切换前状态"; fi
    die "正式路径自检失败，恢复未确认"
  fi
  if ! publish_install_info "$_sw_version" "$3" "$4"; then
    if finish_swap; then die "安装信息落盘失败，已恢复切换前状态"; fi
    die "安装信息落盘失败，恢复未确认"
  fi
  SWAP_PENDING=0
  finish_swap
}

deploy() {
  chmod 755 "$1" 2>/dev/null || { warn "无法设置候选执行权限"; return 1; }
  chown 0:0 "$1" 2>/dev/null
  DEPLOY_VERSION=$(probe_version "$1") || { warn "新本体自检失败（未替换现有文件）"; return 2; }
  if [ -n "$M_VER" ] && [ "$DEPLOY_VERSION" != "$M_VER" ]; then
    warn "新本体报告版本 $DEPLOY_VERSION 与清单版本 $M_VER 不符（未替换现有文件）"
    return 2
  fi

  begin_swap
  if [ -f "$SWAP_DIR/previous" ] && _current_version=$(probe_version "$BIN"); then
    # 持久备份是独立副本，避免以后本体在原 inode 上写入时连备份一起改动。
    cp -p "$SWAP_DIR/previous" "$SWAP_DIR/candidate" 2>/dev/null || die "暂存当前本体失败，未切换"
    _bak_version=$(probe_version "$SWAP_DIR/candidate") || die "备份副本自检失败，未切换"
    [ "$_bak_version" = "$_current_version" ] || die "备份副本版本不一致，未切换"
    mv -f "$SWAP_DIR/candidate" "$BAK" 2>/dev/null || die "更新可用备份失败，未切换"
    say "  已保存最后一个可用版本 $_bak_version 到 $BAK"
  elif [ -f "$BIN" ]; then
    warn "现有本体不可用；不会把它保存为回退备份"
  fi
  switch_verified_binary "$1" "$DEPLOY_VERSION" "$MANIFEST_URL" "$M_SUM"
}

rollback() {
  [ -f "$BAK" ] || die "没有可回退的备份 $BAK"
  _backup_version=$(probe_version "$BAK") || die "备份自检失败，拒绝覆盖当前本体"
  begin_swap
  _rollback_tmp="$SWAP_DIR/candidate"
  cp "$BAK" "$_rollback_tmp" 2>/dev/null || die "回退失败：复制备份失败"
  chmod 755 "$_rollback_tmp" 2>/dev/null || die "回退失败：权限设置失败"
  chown 0:0 "$_rollback_tmp" 2>/dev/null
  _staged_version=$(probe_version "$_rollback_tmp") || die "回退失败：暂存备份自检失败，当前本体未改动"
  [ "$_staged_version" = "$_backup_version" ] || die "回退失败：暂存版本不一致，当前本体未改动"
  _sum=$(sha256sum "$_rollback_tmp" 2>/dev/null) || die "回退失败：无法计算备份摘要"
  _sum=${_sum%% *}
  switch_verified_binary "$_rollback_tmp" "$_backup_version" "rollback:$BAK" "$_sum"
  say "已回退（版本 $_backup_version）；安装信息已更新"
  return 0
}

# ---------- 子命令 ----------

cmd_status() {
  inspect_bin
  case "$BIN_STATE" in
    ready)  echo "state=ready version=$BIN_VERSION path=$BIN" ;;
    broken) echo "state=broken path=$BIN" ;;
    *)      echo "state=missing path=$BIN" ;;
  esac
}

cmd_check() {
  check_arch || die "本模块只支持 arm64 设备（当前 $(uname -m)）"
  need_downloader || exit 1
  say "查询 $MANIFEST_URL ..."
  load_manifest || die "取不到更新清单或清单不符合 HTTPS/元数据要求"
  _ver=$M_VER; _size=$M_SIZE; _pub=$M_PUB

  inspect_bin
  case "$BIN_STATE" in
    ready)
      say "已装：  $BIN_VERSION"
      say "最新：  $_ver"
      if [ "$BIN_VERSION" = "$_ver" ]; then
        say "已是最新，不需要动。"
      else
        say "有新版本。升级请用本体自己的更新，模块不代劳："
        say "  su -c magpie update check    # 只查"
        say "  su -c magpie update          # 装并重启"
      fi
      ;;
    broken)
      say "本地：  本体存在但跑不起来（$BIN）"
      say "最新：  $_ver（$(human_size "$_size")）"
      say "重装可修：sh install.sh install --yes"
      ;;
    *)
      say "本地：  未安装"
      say "可装：  $_ver（$(human_size "$_size")）"
      [ -n "$_pub" ] && say "发布：  $_pub"
      say "安装：  sh install.sh install --yes"
      ;;
  esac
  return 0
}

# 取回清单里的关键字段，供 plan / install 共用
# 设置: M_VER M_SIZE M_SUM M_GH M_CDN
MANIFEST_DIR=''
clear_manifest_tmp() {
  [ -n "$MANIFEST_DIR" ] || return 0
  rm -f "$MANIFEST_DIR/manifest" "$MANIFEST_DIR/manifest.raw" 2>/dev/null
  rmdir "$MANIFEST_DIR" 2>/dev/null || :
  MANIFEST_DIR=''
}

load_manifest() {
  if ! valid_download_url "$MANIFEST_URL"; then warn "清单地址必须是 HTTPS 且不能包含用户名或密码"; return 1; fi
  case "$ASSET_KEY" in ''|*[!a-zA-Z0-9._-]*) warn "资产名不合法"; return 1 ;; esac
  mkdir -p "$magpie_path" 2>/dev/null || return 1
  MANIFEST_DIR=$(mktemp -d "$magpie_path/.manifest.XXXXXX") || return 1
  _manifest_file="$MANIFEST_DIR/manifest"
  fetch_manifest "$_manifest_file" || { clear_manifest_tmp; return 1; }
  _seg=$(extract_asset "$_manifest_file")
  M_VER=$(str_field version < "$_manifest_file")
  M_PUB=$(str_field published < "$_manifest_file")
  M_SIZE=$(printf '%s\n' "$_seg" | num_field size)
  M_SUM=$(printf '%s\n' "$_seg" | str_field sha256)
  M_GH=$(printf '%s\n' "$_seg" | str_field github)
  M_CDN=$(printf '%s\n' "$_seg" | str_field url)
  clear_manifest_tmp
  if [ -z "$_seg" ] || ! printf '%s\n' "$M_VER" | LC_ALL=C grep -Eq '^[0-9]+(\.[0-9]+){2}([+-][0-9A-Za-z.+-]+)?$'; then
    warn "清单缺少目标资产或有效版本"; return 1
  fi
  case "$M_SIZE" in ''|0*|*[!0-9]*) warn "清单必须声明正整数资产大小"; return 1 ;; esac
  if [ "${#M_SIZE}" -gt 9 ] || [ "$M_SIZE" -gt 536870912 ]; then warn "清单资产大小超出上限"; return 1; fi
  if [ "${#M_SUM}" -ne 64 ] || ! printf '%s\n' "$M_SUM" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$'; then
    warn "清单缺少有效 SHA-256"; return 1
  fi
  M_SUM=$(printf '%s' "$M_SUM" | tr A-F a-f)
  if [ -z "$M_CDN$M_GH" ]; then warn "清单缺少下载地址"; return 1; fi
  for _asset_url in "$M_CDN" "$M_GH"; do
    [ -z "$_asset_url" ] || valid_download_url "$_asset_url" || { warn "清单下载地址必须是 HTTPS 且不含用户凭据"; return 1; }
  done
}

cmd_plan() {
  check_arch || { say "✗ 本模块只支持 arm64 设备（当前 $(uname -m)）"; return 1; }
  need_downloader || return 1
  if ! load_manifest; then
    say "✗ 取不到更新清单（$MANIFEST_URL）——检查网络后重试"
    return 1
  fi

  say "将安装 magpie ${M_VER:-未知版本}"
  say "  目标目录  $BIN_DIR"
  say "  下载大小  $(human_size "$M_SIZE")"
  say "  来源      $MANIFEST_URL"
  say "  校验      sha256 $(printf '%s' "$M_SUM" | cut -c1-16)…（清单给出，走 TLS）"
  say "  落盘      $BIN"
  say ""
  say "说明："
  say "  · 只写 bin/magpie，不动 data/、配置、账号、provider、密钥"
  say "  · 已装好的本体不会被覆盖，除非显式 install --yes"
  say "  · 之后的版本升级请用本体自己的： su -c magpie update"
  say "  · 真实性依赖清单来源（magpie 本体的自动更新也是这么校验的）"
  [ -n "$M_GH" ]  && say "  · 发布页  $M_GH"
  [ -n "$M_CDN" ] && say "  · 备用源  $M_CDN"
  return 0
}

cmd_install() {
  _yes=0
  for a in "$@"; do [ "$a" = "--yes" ] && _yes=1; done

  check_arch || die "本模块只支持 arm64 设备（当前 $(uname -m)）"

  if [ "$_yes" = "0" ]; then
    inspect_bin
    if [ "$BIN_STATE" = ready ]; then
      say "已存在可用本体（$BIN_VERSION），不覆盖。"
      say "要重装请显式加 --yes：sh install.sh install --yes"
      say "要升级请用本体自己的：su -c magpie update"
      return 0
    fi
  fi

  # 未带 --yes：走「再点一次」确认。终端里不可交互，所以不读 stdin。
  if [ "$_yes" = "0" ] && [ -f "$PENDING" ]; then
    _t=$(cat "$PENDING" 2>/dev/null)
    _now=$(date +%s)
    case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
    if [ $((_now - _t)) -le "$CONFIRM_WINDOW" ]; then
      say "已确认，开始安装。"
      _yes=1
      rm -f "$PENDING" 2>/dev/null
    fi
  fi

  if [ "$_yes" = "0" ]; then
    cmd_plan || die "无法获取安装信息"
    say ""
    say "确认后才会下载："
    say "  · 再点一次 [执行]，${CONFIRM_WINDOW} 秒内即开始；或直接跑 install --yes"
    date +%s > "$PENDING" 2>/dev/null
    chmod 600 "$PENDING" 2>/dev/null
    return 0
  fi
  rm -f "$PENDING" 2>/dev/null

  mkdir -p "$magpie_path" 2>/dev/null
  acquire_lock
  need_downloader || exit 1
  # 持锁说明没有别的安装器在跑：回收上次被强杀留下的半截下载（每份约 100 MB）。
  for _old in "$BIN_DIR"/.magpie.new.*; do
    [ -f "$_old" ] && [ ! -L "$_old" ] && rm -f "$_old" 2>/dev/null && say "  已清理上次中断留下的临时文件 ${_old##*/}"
  done

  say "取更新清单 ..."
  if ! load_manifest; then
    die "取不到更新清单（需要 HTTPS），或清单缺少可验证的资产元数据"
  fi

  check_space "$M_SIZE"

  # 先建目录：临时文件要落在同一个文件系统上，才能用 mv 原子替换
  mkdir -p "$BIN_DIR" 2>/dev/null || die "无法创建 $BIN_DIR"
  chmod 755 "$BIN_DIR" 2>/dev/null

  say "开始安装 magpie ${M_VER:-未知版本}（$(human_size "$M_SIZE")）"
  DOWNLOAD_TMP=$(mktemp "$BIN_DIR/.magpie.new.XXXXXX") || die "无法创建临时下载文件"
  download_verified "$DOWNLOAD_TMP" "$M_SIZE" "$M_SUM" "$M_CDN" "$M_GH" || die "所有来源都失败了，本体未改动"

  say "部署 ..."
  deploy "$DOWNLOAD_TMP"
  _deploy_rc=$?
  if [ "$_deploy_rc" -ne 0 ]; then
    if [ "$_deploy_rc" -eq 2 ] && [ -f "$DOWNLOAD_TMP" ]; then
      mv -f "$DOWNLOAD_TMP" "$BIN.rejected" 2>/dev/null || die "新本体跑不起来，无法保存失败样本；未替换当前本体"
      if [ ! -f "$BIN" ] && [ ! -f "$BAK" ]; then
        say "  首次安装，无可用备份；失败样本保留在 $BIN.rejected"
      else
        say "  原有本体与可用备份保持不变；失败样本保留在 $BIN.rejected"
      fi
      die "新本体跑不起来，未替换当前本体"
    fi
    die "部署失败，现有本体未主动替换"
  fi

  say "✓ 已安装 magpie $DEPLOY_VERSION"
  say "  位置  $BIN"
  [ -f "$BAK" ] && say "  备份  $BAK（回退：sh install.sh rollback）"
  say ""
  say "下一步：点 [执行]，或 sh $MODDIR/scripts/magpie.service start"
  return 0
}

cmd_rollback() {
  acquire_lock
  rollback
  return 0
}

# ---------- 入口 ----------

# 先装 trap 再触碰锁；check/plan 的清单下载也必须能被信号取消。
exec 8>&-  # 预留本脚本的 FD，不解锁调用者可能传入的同号 FD。
trap cleanup_install EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# 统一放在分派之前：check / plan 也会创建目录和清单临时文件，rollback 会
# 加锁并覆盖本体；status 会执行本体 --version。它们都不能绕过路径校验。
# help / 未知命令不触碰目标，仍可在配置损坏时查看用法。
case "${1:-}" in
  status|check|plan|install|rollback) check_target "$1" ;;
esac

case "${1:-}" in
  status)   cmd_status ;;
  check)    cmd_check ;;
  plan)     cmd_plan ;;
  install)  shift; cmd_install "$@" ;;
  rollback) cmd_rollback ;;
  ""|help|-h|--help)
    say "用法: sh install.sh {status|check|plan|install [--yes]|rollback}"
    ;;
  *) die "未知命令 $1" ;;
esac
