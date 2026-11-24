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

CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
magpie_path=/data/adb/magpie
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

BIN_DIR="$magpie_path/bin"
BIN="$BIN_DIR/magpie"
BAK="$BIN_DIR/magpie.bak"
INFO="$magpie_path/install-info.txt"
LOCK="$magpie_path/.install.lock"
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
      if (match(t, /^[0-9]+/)) { print substr(t, 1, RLENGTH); exit } }'
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
# 模块脚本不能假定 wget 在 PATH 上。实测：同样调用 `sh 脚本`，有的上下文里
# `command -v wget` 是空的（模块被管理器/服务拉起时更明显），于是下载全失败。
# 这里按 环境变量 → PATH 里的 wget → 三大 Root 方案自带的 busybox → curl 依次找。

DL_CMD=""
DL_KIND=""

pick_downloader() {
  [ -n "$DL_KIND" ] && return 0
  if [ -n "${MAGPIE_DL:-}" ]; then
    DL_CMD="$MAGPIE_DL"; DL_KIND=curl
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    DL_CMD="wget"; DL_KIND=wget
    return 0
  fi
  for _bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$_bb" ] && "$_bb" wget --help >/dev/null 2>&1; then
      DL_CMD="$_bb"; DL_KIND=busybox
      return 0
    fi
  done
  if command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1; then
    DL_CMD="busybox"; DL_KIND=busybox
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    DL_CMD="curl"; DL_KIND=curl
    return 0
  fi
  return 1
}

# 下载超时分两种，不能合成一个数：
#   DL_STALL  多久没有任何数据就放弃（连接超时 / 传输停滞）。默认 60 秒。
#   DL_TOTAL  整次下载的总上限。默认 30 分钟。
# 以前 wget 只给了 -T 60（那是停滞超时，不是总时限），curl 只给了 --max-time 600
# （那是总时限）：慢网下 87 MB 走 curl 需要 >145 KB/s，反而更容易被掐；
# 而 wget 那侧一旦服务器长期不响应，也没有总上限兜底。
DL_STALL=${MAGPIE_DL_STALL:-60}
DL_TOTAL=${MAGPIE_DL_TIMEOUT:-1800}

# 有 timeout 就用它给 wget 补一个总上限（wget 自己没有总时限参数）。
# 没有就直接跑：停滞超时还在，不会永远挂着 —— 只是少一层保险。
have_timeout() { command -v timeout >/dev/null 2>&1; }

# 下载 $1 到 $2。成功返回 0。
dl_fetch() {
  _url="$1"; _out="$2"
  pick_downloader || return 127
  # 放到后台再 wait：shell 要等前台命令结束才会执行 trap，
  # 87 MB 下到一半按 Ctrl-C / 管理器被杀时就会干等好几分钟。
  # wait 是可中断的，信号一到马上就能跑 on_signal。
  case "$DL_KIND" in
    wget|busybox)
      # busybox 是 multicall，后面还要跟子命令 wget；系统 wget 不用。
      if [ "$DL_KIND" = "busybox" ]; then
        _wget_wrap="$DL_CMD wget"
      else
        _wget_wrap="wget"
      fi
      # $_wget_wrap 故意不加引号：busybox 那条是 "busybox wget" 两个词，
      # 加引号会整体当一个命令名去找。系统 wget 那条只有一个词，分词后等价。
      # shellcheck disable=SC2086
      if have_timeout; then
        timeout "$DL_TOTAL" $_wget_wrap -q -O "$_out" -T "$DL_STALL" "$_url" 2>/dev/null &
      else
        $_wget_wrap -q -O "$_out" -T "$DL_STALL" "$_url" 2>/dev/null &
      fi
      ;;
    curl)
      # --speed-limit/--speed-time 等价于 wget 的 -T：60 秒内平均低于 1 KB/s 就断。
      # --max-time 才是总上限。
      "$DL_CMD" -fsSL --connect-timeout "$DL_STALL" \
        --speed-limit 1024 --speed-time "$DL_STALL" \
        --max-time "$DL_TOTAL" -o "$_out" "$_url" 2>/dev/null &
      ;;
    *) return 127 ;;
  esac
  DL_PID=$!
  wait "$DL_PID"
  _rc=$?
  DL_PID=""
  return $_rc
}

# 下载器的人话名字，用于报错
dl_name() {
  pick_downloader || { echo "无"; return 0; }
  case "$DL_KIND" in
    busybox) echo "$DL_CMD wget" ;;
    *)       echo "$DL_CMD" ;;
  esac
}

fetch_manifest() {
  # $1 = 输出文件（压缩后的版本）
  _raw="$1.raw"
  rm -f "$1" "$_raw" 2>/dev/null

  # 清单很小，但同样容许一次抖动
  _ok=0
  for _try in 1 2; do
    [ "$_try" = "2" ] && sleep 2
    if dl_fetch "$MANIFEST_URL" "$_raw" && [ -s "$_raw" ]; then
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
probe_version() {
  _f="$1"
  [ -f "$_f" ] || return 1
  [ -x "$_f" ] || return 1
  _v=$(HOME="$magpie_path/data" MAGPIE_HOME="$magpie_path/data" \
       timeout 60 "$_f" --version 2>/dev/null | head -1)
  case "$_v" in
    magpie\ *) echo "${_v#magpie }"; return 0 ;;
  esac
  return 1
}

# missing | broken | ready
bin_state() {
  if [ ! -e "$BIN" ]; then
    echo missing; return 0
  fi
  if probe_version "$BIN" >/dev/null 2>&1; then
    echo ready
  else
    echo broken
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
  case "$magpie_path" in
    /|/data|/data/adb|/sdcard|/sdcard/*|/storage|/storage/*|/mnt|/mnt/*|/system|/system/*)
      die "拒绝把本体安装到 $magpie_path" ;;
  esac
  case "$magpie_path" in
    /*) ;;
    *) die "magpie_path 必须是绝对路径：$magpie_path" ;;
  esac
  # 逐级上溯，不允许路径里有符号链接指向别处
  _d="$magpie_path"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -L "$_d" ]; then
      die "$_d 是符号链接，出于安全考虑不接受"
    fi
    _d=$(dirname "$_d")
  done
  return 0
}

check_space() {
  _need="$1"
  [ -n "$_need" ] || _need=104857600
  # 同时要放临时文件和备份，按两倍再加 50MB 余量
  _want=$((_need * 2 + 52428800))
  _free=$(df -k "$magpie_path" 2>/dev/null | tail -1 | awk '{print $4}')
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

# 当前进程是否持有安装锁。release_lock 只释放自己那把，避免误删别人的锁。
LOCK_HELD=""

acquire_lock() {
  mkdir -p "$magpie_path" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid" 2>/dev/null
    LOCK_HELD=1
    return 0
  fi
  _p=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
    die "另一个安装正在进行（PID $_p）。等它结束，或删除 $LOCK"
  fi
  warn "发现过期锁，已清理"
  # mv 是原子的：只有一个进程能把旧锁挪走，另一个会失败。
  # 直接 rm -rf 会让两个进程都以为清掉了旧锁，然后各自 mkdir 成功、同时部署。
  _stale="$LOCK.stale.$$"
  if mv "$LOCK" "$_stale" 2>/dev/null; then
    rm -rf "$_stale" 2>/dev/null
  else
    rm -rf "$LOCK" 2>/dev/null
  fi
  mkdir "$LOCK" 2>/dev/null || die "无法获取安装锁 $LOCK"
  echo $$ > "$LOCK/pid" 2>/dev/null
  LOCK_HELD=1
  return 0
}

# 幂等：trap 和显式释放都会调它
release_lock() {
  [ -n "$LOCK_HELD" ] || return 0
  LOCK_HELD=""
  rm -rf "$LOCK" 2>/dev/null
}

# 正在下载的子进程；收到信号时要一并收掉，免得留下没人管的 wget
DL_PID=""

# 收到 INT/TERM/HUP：收掉下载、放锁、退出。
# 原先是 trap 'release_lock' INT TERM —— 只放锁不退出，脚本会继续下载、
# 继续替换二进制，而锁已经没了，另一个安装可以同时进来。
on_signal() {
  [ -n "$DL_PID" ] && kill -9 "$DL_PID" 2>/dev/null
  release_lock
  exit 130
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
      rm -f "$_tmp" 2>/dev/null
      if ! dl_fetch "$_u" "$_tmp"; then
        warn "下载失败，换下一个来源"
        continue
      fi
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

# ---------- 部署 ----------

deploy() {
  _tmp="$1"
  mkdir -p "$BIN_DIR" 2>/dev/null || die "无法创建 $BIN_DIR"
  chmod 755 "$BIN_DIR" 2>/dev/null

  if [ -f "$BIN" ]; then
    say "  备份现有本体到 $BAK"
    cp -f "$BIN" "$BAK" 2>/dev/null || die "备份失败，已中止"
    chmod 755 "$BAK" 2>/dev/null
  fi

  chmod 755 "$_tmp" 2>/dev/null || die "无法设置执行权限"
  chown 0:0 "$_tmp" 2>/dev/null

  # 同一文件系统内 mv 是原子的：要么旧文件，要么新文件，不会出现半截
  mv -f "$_tmp" "$BIN" 2>/dev/null || die "替换 $BIN 失败"
  chmod 755 "$BIN" 2>/dev/null
  chown 0:0 "$BIN" 2>/dev/null
  return 0
}

verify_installed() {
  _v=$(probe_version "$BIN")
  [ -n "$_v" ] || return 1
  echo "$_v"
  return 0
}

rollback() {
  [ -f "$BAK" ] || die "没有可回退的备份 $BAK"
  say "回退到备份 ..."
  cp -f "$BAK" "$BIN" 2>/dev/null || die "回退失败"
  chmod 755 "$BIN" 2>/dev/null
  chown 0:0 "$BIN" 2>/dev/null
  _v=$(probe_version "$BIN")
  say "已回退${_v:+（版本 $_v）}"
  return 0
}

record_info() {
  _v="$1"; _src="$2"; _sum="$3"
  {
    echo "version=$_v"
    echo "installed=$(date +'%Y-%m-%d %H:%M:%S')"
    echo "source=$_src"
    echo "sha256=$_sum"
    echo "asset=$ASSET_KEY"
  } > "$INFO" 2>/dev/null
  chmod 600 "$INFO" 2>/dev/null
}

# ---------- 子命令 ----------

cmd_status() {
  _st=$(bin_state)
  case "$_st" in
    ready)  echo "state=ready version=$(probe_version "$BIN") path=$BIN" ;;
    broken) echo "state=broken path=$BIN" ;;
    *)      echo "state=missing path=$BIN" ;;
  esac
}

cmd_check() {
  check_arch || die "本模块只支持 arm64 设备（当前 $(uname -m)）"
  say "查询 $MANIFEST_URL ..."
  mkdir -p "$magpie_path" 2>/dev/null
  _mf="$magpie_path/.manifest.tmp"
  fetch_manifest "$_mf" || { rm -f "$_mf"; die "取不到更新清单（网络不通，或被拦）"; }
  _seg=$(extract_asset "$_mf")
  _ver=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$_mf" | head -1)
  _size=$(printf '%s' "$_seg" | num_field size)
  _pub=$(str_field published < "$_mf")
  rm -f "$_mf"
  [ -n "$_seg" ] || die "清单里没有 $ASSET_KEY"

  case "$(bin_state)" in
    ready)
      _cur=$(probe_version "$BIN")
      say "已装：  $_cur"
      say "最新：  $_ver"
      if [ "$_cur" = "$_ver" ]; then
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
load_manifest() {
  _mf="$magpie_path/.manifest.tmp"
  mkdir -p "$magpie_path" 2>/dev/null
  fetch_manifest "$_mf" || { rm -f "$_mf"; return 1; }
  _seg=$(extract_asset "$_mf")
  M_VER=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$_mf" | head -1)
  M_SIZE=$(printf '%s' "$_seg" | num_field size)
  M_SUM=$(printf '%s' "$_seg" | str_field sha256)
  M_GH=$(printf '%s' "$_seg" | str_field github)
  M_CDN=$(printf '%s' "$_seg" | str_field url)
  rm -f "$_mf"
  [ -n "$_seg" ] || return 1
  return 0
}

cmd_plan() {
  check_arch || { say "✗ 本模块只支持 arm64 设备（当前 $(uname -m)）"; return 1; }
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
  check_target

  _st=$(bin_state)
  if [ "$_st" = "ready" ] && [ "$_yes" = "0" ]; then
    say "已存在可用本体（$(probe_version "$BIN")），不覆盖。"
    say "要重装请显式加 --yes：sh install.sh install --yes"
    say "要升级请用本体自己的：su -c magpie update"
    return 0
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
  trap 'release_lock' EXIT
  trap 'on_signal' INT TERM HUP

  say "取更新清单 ..."
  if ! load_manifest; then
    release_lock
    die "取不到更新清单（$MANIFEST_URL）"
  fi
  [ -n "$M_SUM" ] || { release_lock; die "清单没给 sha256，拒绝安装"; }

  check_space "$M_SIZE"

  # 先建目录：临时文件要落在同一个文件系统上，才能用 mv 原子替换
  mkdir -p "$BIN_DIR" 2>/dev/null || { release_lock; die "无法创建 $BIN_DIR"; }
  chmod 755 "$BIN_DIR" 2>/dev/null

  say "开始安装 magpie ${M_VER:-未知版本}（$(human_size "$M_SIZE")）"
  _tmp="$BIN_DIR/.magpie.new.$$"
  if ! download_verified "$_tmp" "$M_SIZE" "$M_SUM" "$M_CDN" "$M_GH"; then
    rm -f "$_tmp" 2>/dev/null
    release_lock
    die "所有来源都失败了，本体未改动"
  fi

  say "部署 ..."
  if ! deploy "$_tmp"; then
    rm -f "$_tmp" 2>/dev/null
    release_lock
    die "部署失败"
  fi

  say "启动自检 ..."
  _got=$(verify_installed)
  if [ -z "$_got" ]; then
    if [ -f "$BAK" ]; then
      warn "新本体跑不起来，回退"
      rollback || true
    else
      # 首次安装没有备份可退：把文件挪开，绝不留一个「看起来已安装」的正式文件
      warn "新本体跑不起来，已移除（首次安装，无备份可回退）"
      mv -f "$BIN" "$BIN.rejected" 2>/dev/null || rm -f "$BIN" 2>/dev/null
      if [ -f "$BIN.rejected" ]; then
        say "  失败样本留在 $BIN.rejected，确认无用后可直接删"
        say "  大小 $(stat -c %s "$BIN.rejected" 2>/dev/null) 字节，sha256 $(sha256sum "$BIN.rejected" 2>/dev/null | awk '{print $1}')"
      fi
    fi
    release_lock
    die "安装失败，本体未生效"
  fi

  record_info "$_got" "$MANIFEST_URL" "$M_SUM"
  release_lock

  say "✓ 已安装 magpie $_got"
  say "  位置  $BIN"
  [ -f "$BAK" ] && say "  备份  $BAK（回退：sh install.sh rollback）"
  say ""
  say "下一步：点 [执行]，或 sh $MODDIR/scripts/magpie.service start"
  return 0
}

cmd_rollback() {
  acquire_lock
  trap 'release_lock' EXIT
  trap 'on_signal' INT TERM HUP
  rollback
  release_lock
  return 0
}

# ---------- 入口 ----------

case "$1" in
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
