#!/system/bin/sh
# Magpie for Android - 自检脚本（只读检查，不改任何配置）
# 用法: su -c sh /data/adb/modules/magpie/scripts/doctor.sh

# 模块脚本被管理器或 /system/bin/sh 拉起时，PATH 里往往只有系统目录，
# 那里没有 wget / busybox。把各 Root 方案的 bin 目录补进来。
export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/magpie

CONF=/data/adb/magpie/scripts/magpie.config
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
magpie_path=/data/adb/magpie
MAGPIE_ADDR="127.0.0.1:3425"
MAGPIE_WEB_ADDR=""
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

API_PORT=${MAGPIE_ADDR##*:}
[ -n "$API_PORT" ] || API_PORT=3425
WEB_PORT=${MAGPIE_WEB_ADDR##*:}
[ -n "$WEB_PORT" ] || WEB_PORT=3430

OK=0; BAD=0; WARN=0
ok()   { OK=$((OK + 1));    echo "  ✓ $1"; }
bad()  { BAD=$((BAD + 1));  echo "  ✗ $1"; [ -n "$2" ] && echo "      → $2"; }
warn() { WARN=$((WARN + 1)); echo "  ! $1"; [ -n "$2" ] && echo "      → $2"; }

# 进程识别与局域网地址，和运行期脚本共用同一份实现
_NETLIB="$MODDIR/scripts/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  magpie_main_pid() { pidof magpie 2>/dev/null | tr ' ' '\n' | head -1; }
  magpie_all_pids() { pidof magpie 2>/dev/null | tr ' ' '\n' | grep -v '^$'; }
  lan_ip() { return 1; }
fi

# 取 HTTP 状态码；连不上则输出空。
# 注意不能直接调 `wget`：这条路在很多机型上根本不存在（系统没有 wget，
# 而 Root 方案的 busybox 也不一定带 applet 软链），以前会导致
# 「进程在跑、端口在听、但自检说网关无响应」的假报警。用 curl > busybox > wget 兜住。
DL_BB=""
for _b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
  [ -x "$_b" ] && { DL_BB="$_b"; break; }
done

http_code() {
  _u="$1"; _t="${2:-5}"
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -m "$_t" -w '%{http_code}' "$_u" 2>/dev/null
    return 0
  fi
  if [ -n "$DL_BB" ]; then
    "$DL_BB" wget -S -O /dev/null -T "$_t" "$_u" 2>&1
  else
    wget -S -O /dev/null -T "$_t" "$_u" 2>&1
  fi | sed -n 's/.*HTTP\/1\.[01] \([0-9]\{3\}\).*/\1/p' | tail -1
}

echo "Magpie AI 网关 · 自检"
echo "  模块   $MODDIR"
echo "  配置   $CONF"
echo "  监听   网关 $MAGPIE_ADDR  面板 ${MAGPIE_WEB_ADDR:-未设置}"
echo

echo "[1/9] 本体与进程"
_st_raw=$(sh "$MODDIR/scripts/install.sh" status 2>/dev/null)
_st=$(printf '%s' "$_st_raw" | sed -n 's/^state=\([a-z]*\).*/\1/p')
_bv=$(printf '%s' "$_st_raw" | sed -n 's/.*version=\([^ ]*\).*/\1/p')
case "$_st" in
  ready)
    ok "本体可用${_bv:+：magpie $_bv}" ;;
  broken)
    bad "本体存在但跑不起来（$magpie_path/bin/magpie）" \
        "重装可修：sh $MODDIR/scripts/install.sh install --yes" ;;
  missing|'')
    bad "本体未安装" \
        "本模块不含本体。安装：sh $MODDIR/scripts/install.sh install --yes（或在管理器点 [执行]）" ;;
  *)
    warn "本体状态未知：$_st" ;;
esac

PID=$(magpie_main_pid 2>/dev/null)
if [ -n "$PID" ]; then
  ok "服务在运行（PID $PID）"
  _oom=$(cat "/proc/$PID/oom_score_adj" 2>/dev/null)
  case "$_oom" in
    -1000) ok "oom_score_adj -1000（不会被 LMKD 回收）" ;;
    '')    warn "读不到 oom_score_adj" ;;
    *)     warn "oom_score_adj $_oom（不是 -1000）" "restart 服务会试着改回 -1000；长期偏低可查省电类模块是否在改它" ;;
  esac
elif [ "$_st" = "ready" ]; then
  bad "服务未运行" "sh $MODDIR/scripts/magpie.service start"
else
  # 本体都没就绪，服务没跑属于预期，不必再报一次错
  warn "服务未运行（本体未就绪，属预期）" "装好本体后再启动：sh $MODDIR/scripts/magpie.service start"
fi

echo "[2/9] 端口监听"
for _p in "$API_PORT:网关" "$WEB_PORT:面板"; do
  _port=${_p%%:*}; _name=${_p##*:}
  if ss -ltn 2>/dev/null | grep -q "[:.]$_port "; then
    ok "$_name 端口 $_port 在监听"
  else
    bad "$_name 端口 $_port 没有监听" "看 $magpie_path/run/magpie.log 的启动报错"
  fi
done

echo "[3/9] 本机可用性"
_c=$(http_code "http://127.0.0.1:$API_PORT/" 5)
if [ "$_c" = "200" ]; then
  ok "网关响应正常（HTTP $_c）"
elif [ -n "$_c" ]; then
  warn "网关返回 HTTP $_c（预期 200）"
else
  bad "网关无响应" "进程在但端口不通，通常是还没启动完或端口被占"
fi

echo "[4/9] 面板与访问密码"
WEB_KEY=$(cat "$magpie_path/data/web.key" 2>/dev/null)
if [ -n "$WEB_KEY" ]; then
  ok "访问密码存在（${#WEB_KEY} 位）"
  _c=$(http_code "http://127.0.0.1:$WEB_PORT/?k=$WEB_KEY" 5)
  case "$_c" in
    200|303) ok "带密码可访问面板（HTTP $_c）" ;;
    "")      bad "面板无响应" "检查 $WEB_PORT 是否被占" ;;
    401)     warn "面板没有接受这把密码（HTTP 401）" "浏览器里能打开就忽略这条；打不开则重启服务重建 data/web.key" ;;
    *)       warn "面板返回 HTTP $_c" ;;
  esac
else
  warn "没有 data/web.key" "首次启动服务时会自动生成"
fi

echo "[5/9] 网关密钥"
if [ -x "$magpie_path/bin/magpie" ]; then
  _n=$(HOME="$magpie_path/data" MAGPIE_HOME="$magpie_path/data" \
       "$magpie_path/bin/magpie" gateway-key list 2>/dev/null \
       | grep -c 'enabled')
  if [ "$_n" -gt 0 ] 2>/dev/null; then
    ok "有 $_n 把已启用的网关密钥"
  else
    warn "没有已启用的网关密钥" "局域网访问需要它：magpie gateway-key add phone"
  fi
fi

echo "[6/9] CA 证书包"
CA="$magpie_path/data/certs/ca-bundle.crt"
if [ -s "$CA" ]; then
  _n=$(grep -c 'BEGIN CERTIFICATE' "$CA" 2>/dev/null)
  ok "证书包可用（$_n 张，权限 $(stat -c %a "$CA" 2>/dev/null)）"
else
  warn "没有证书包" "重启服务会自动生成；HTTPS 若失败可删掉它再重启"
fi

echo "[7/9] 局域网暴露"
case "$MAGPIE_ADDR" in
  127.0.0.1:*|localhost:*)
    ok "网关只监听本机，局域网不可达" ;;
  *)
    warn "网关已对局域网开放"
    # 实时算，不读 run/lan.url —— 那是启动时的快照，WiFi 换过就过期了
    _lan=$(lan_ip)
    if [ -n "$_lan" ]; then
      echo "      → 现在可用的地址 http://$_lan:$API_PORT/v1"
      echo "      → 别的设备要带一把已启用的网关密钥"
    else
      echo "      → 当前没有可用局域网地址（未连 WiFi / 热点未开，或只有移动数据）"
    fi
    ;;
esac
case "$MAGPIE_WEB_ADDR" in
  ""|127.0.0.1:*|localhost:*) ;;
  *) warn "面板已对局域网开放" "不知道访问密码的人会看到 401，但密码泄露等于网关密钥也泄露" ;;
esac

echo "[8/9] DNS 解析"
# magpie 是静态编译的 Go 程序，解析域名只走 /etc/resolv.conf。
# 这个文件不存在时 Go 会去问 127.0.0.1:53 / [::1]:53，安卓上没人监听，
# 于是原生通道全部 `connection refused`——所以先看文件在不在，再看上游答不答。
if [ -r /etc/resolv.conf ]; then
  _dns=$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
  if [ -n "$_dns" ]; then
    ok "/etc/resolv.conf 存在（上游 ${_dns% }）"
  else
    bad "/etc/resolv.conf 里没有 nameserver" "改 MAGPIE_DNS 后重启服务，或重启一次手机让覆盖生效"
  fi
else
  bad "/etc/resolv.conf 不存在" "原生 Go 通道会全部解析失败；重启一次手机让模块覆盖生效"
fi
if [ -n "$DL_BB" ]; then
  # 覆盖还没挂上时也测一下配置里的第一台上游：能分辨「文件没生效」和「DNS 本身不通」
  _srv=${_dns%% *}
  [ -n "$_srv" ] || _srv=${MAGPIE_DNS%% *}
  [ -n "$_srv" ] || _srv=223.5.5.5
  # nslookup 会把「服务器」也打成 Address 行，所以只看 Name: 之后的才是答案
  _addr=$("$DL_BB" nslookup api.deepseek.com "$_srv" 2>/dev/null \
    | awk '/^Name:/{f=1;next} f && /^Address [0-9]*: /{sub(/^Address [0-9]*: /,""); print $1}' | head -1)
  if [ -n "$_addr" ]; then
    ok "上游 $_srv 能解析 api.deepseek.com（$_addr）"
  else
    warn "上游 $_srv 解析 api.deepseek.com 失败" "换一个 MAGPIE_DNS（如 223.5.5.5）后重启服务"
  fi
fi

echo "[9/9] 日志与磁盘"
for _f in "$magpie_path/run/magpie.log" "$magpie_path/run/watchdog.log"; do
  if [ -f "$_f" ]; then
    _sz=$(stat -c %s "$_f" 2>/dev/null)
    _mb=$((_sz / 1048576))
    if [ "$_sz" -gt 5242880 ] 2>/dev/null; then
      warn "${_f##*/} 已 $_mb MB" "超过 5 MB，下次启动会归档为 .1"
    else
      ok "${_f##*/} $_mb MB"
    fi
  fi
done
if touch "$magpie_path/data/.doctor" 2>/dev/null; then
  rm -f "$magpie_path/data/.doctor" 2>/dev/null
  ok "数据目录可写"
else
  bad "$magpie_path/data 不可写" "检查磁盘空间与权限"
fi
_df=$(df -h "$magpie_path/data" 2>/dev/null | tail -1 | awk '{print $4}')
[ -n "$_df" ] && echo "  剩余空间 $_df"

echo
echo "结果：通过 $OK，警告 $WARN，失败 $BAD"
if [ "$BAD" -gt 0 ]; then
  echo "有失败项，按上面的提示处理；日志在 $magpie_path/run/magpie.log"
  exit 1
fi
echo "没有发现致命问题。"
