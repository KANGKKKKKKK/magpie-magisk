#!/system/bin/sh
# Magpie for Android - 自检脚本（只读检查，不改任何配置）
# 用法: su -c sh /data/adb/modules/magpie/scripts/doctor.sh

# 模块脚本被管理器或 /system/bin/sh 拉起时，PATH 里往往只有系统目录，
# 那里没有 wget / busybox。把各 Root 方案的 bin 目录补进来。
export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/magpie

# 进程识别与局域网地址，和运行期脚本共用同一份实现。
# 必须在算端口之前 source：下面要用 addr_port / addr_host / is_loopback_host。
_NETLIB="$MODDIR/scripts/lib.sh"
if [ -f "$_NETLIB" ]; then
  . "$_NETLIB"
else
  magpie_main_pid() { pidof magpie 2>/dev/null | tr ' ' '\n' | head -1; }
  magpie_all_pids() { pidof magpie 2>/dev/null | tr ' ' '\n' | grep -v '^$'; }
  lan_ip() { return 1; }
  addr_host() { case "$1" in \[*\]:*) _h=${1#\[}; echo "${_h%%\]*}" ;; *:*) echo "${1%:*}" ;; *) echo "$1" ;; esac; }
  addr_port() { case "$1" in \[*\]:*) _p=${1##*\]:} ;; *:*) _p=${1##*:} ;; *) return 1 ;; esac; case "$_p" in ''|*[!0-9]*) return 1 ;; esac; echo "$_p"; }
  is_loopback_host() { _h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); case "$_h" in 127.*|localhost|::1|\[::1\]|::ffff:127.*) return 0 ;; esac; return 1; }
fi

CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$CONF" ] || CONF="$MODDIR/scripts/magpie.config"
magpie_path=/data/adb/magpie
MAGPIE_ADDR="127.0.0.1:3425"
MAGPIE_WEB_ADDR=""
# 语法错误的配置不 source：BusyBox ash 会因此整个退出（见 lib.sh magpie_conf_syntax_ok）
if [ -f "$CONF" ] && ! sh -n "$CONF" >/dev/null 2>&1; then
  echo "! 配置文件有语法错误，已改用默认值：$CONF" >&2
  MAGPIE_CONF_ERROR="配置文件有语法错误（$CONF），已按默认值运行"
else
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null
fi

# 端口按 1..65535 校验；非法时留空，由 [2/10] 直接报错，不静默退回默认值
API_PORT=$(addr_port "$MAGPIE_ADDR" 2>/dev/null)
# 面板地址留空是默认用法：与 magpie.service 一致，用「网关主机 + 3430」推出来
WEB_ADDR=${MAGPIE_WEB_ADDR:-"${MAGPIE_ADDR%:*}:3430"}
WEB_PORT=$(addr_port "$WEB_ADDR" 2>/dev/null)
ADDR_ERROR=""
if [ -z "$API_PORT" ]; then
  ADDR_ERROR="MAGPIE_ADDR=$MAGPIE_ADDR 的端口不可用（应为 主机:端口，1-65535；IPv6 用 [::1]:3425）"
elif [ -z "$WEB_PORT" ]; then
  ADDR_ERROR="面板监听地址 $WEB_ADDR 的端口不可用（MAGPIE_WEB_ADDR 应为 主机:端口）"
fi
[ -n "$API_PORT" ] || API_PORT=0
[ -n "$WEB_PORT" ] || WEB_PORT=0

OK=0; BAD=0; WARN=0
ok()   { OK=$((OK + 1));    echo "  ✓ $1"; }
bad()  { BAD=$((BAD + 1));  echo "  ✗ $1"; [ -n "$2" ] && echo "      → $2"; }
warn() { WARN=$((WARN + 1)); echo "  ! $1"; [ -n "$2" ] && echo "      → $2"; }

# 仅对已核验归属的本机回环地址作有界无凭据请求。curl -q 忽略用户配置，
# 不用环境代理、不跟随跳转。工具不满足这些约束时，保留 socket 核验结果。
probe_local_http() (
  command -v curl >/dev/null 2>&1 || exit 2
  _http=$(curl -q --noproxy '*' --proto '=http' --max-time 5 --max-redirs 0 \
    -s -o /dev/null -w '%{http_code}' "http://$1:$2/" 2>/dev/null) || exit 1
  case "$_http" in [1-5][0-9][0-9]) printf '%s\n' "$_http" ;; *) exit 1 ;; esac
)

report_listener() {
  case "$3" in
    'local '*) ok "$1 $2：已核验由 Magpie 监听在回环 ${3#local }" ;;
    nonlocal) ok "$1 $2：已核验由 Magpie 监听，包含非回环地址" ;;
    closed) bad "$1 $2：端口未监听" "检查服务是否运行，或查看启动日志" ;;
    *) warn "$1 $2：监听归属未知" "未能读取内核监听/进程资料，或端口由其它进程监听" ;;
  esac
}

report_scope() {
  _scope_goal=nonlocal
  is_loopback_host "$(addr_host "$2")" && _scope_goal=local
  case "$_scope_goal" in local) _scope_label='仅回环' ;; *) _scope_label='含非回环' ;; esac
  echo "    $1 配置目标：$2（$_scope_label）"
  case "$3" in
    'local '*)
      if [ "$_scope_goal" = local ]; then ok "$1 实际监听仅在回环，与配置目标一致"
      else warn "$1 实际仅在回环，与非回环配置不一致"; fi ;;
    nonlocal)
      if [ "$_scope_goal" = local ]; then
        bad "$1 仍有非回环监听，配置未生效" "不要认为局域网已关闭；先检查启停结果"
      else warn "$1 有实际非回环监听（是否能从别的设备连接仍取决于网卡与防火墙）"; fi ;;
    closed) warn "$1 配置端口目前未监听，不代表配置已经生效" ;;
    *) warn "$1 实际监听范围未知，不能由配置推断是否对外开放" ;;
  esac
}

echo "Magpie AI 网关 · 自检"
echo "  模块   $MODDIR"
echo "  配置   $CONF"
echo "  监听配置   网关 $MAGPIE_ADDR  面板 $WEB_ADDR"
echo

if [ -n "${MAGPIE_CONF_ERROR:-}" ]; then
  echo "  ✗ $MAGPIE_CONF_ERROR"
  echo "      → 修好引号/括号后重启服务：sh -n $CONF 可定位出错行"
  BAD=$((BAD + 1))
  echo
fi

echo "[1/10] 本体与进程"
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

echo "[2/10] 端口监听"
_api_bind=unknown; _web_bind=unknown
if [ -n "$ADDR_ERROR" ]; then
  bad "监听地址配置有误" "$ADDR_ERROR"
else
  if command -v magpie_listener_report >/dev/null 2>&1; then
    _binds=$(magpie_listener_report "$API_PORT" "$WEB_PORT")
    _api_bind=$(printf '%s\n' "$_binds" | sed -n 's/^api=//p')
    _web_bind=$(printf '%s\n' "$_binds" | sed -n 's/^web=//p')
  fi
  report_listener 网关 "$API_PORT" "$_api_bind"
  report_listener 面板 "$WEB_PORT" "$_web_bind"
fi

echo "[3/10] 本机可用性"
case "$_api_bind" in
  'local '*)
    _c=$(probe_local_http "${_api_bind#local }" "$API_PORT"); _http_rc=$?
    if [ "$_http_rc" = 2 ]; then
      warn "没有支持直连探测的 curl，未做 HTTP 检查"
    elif [ "$_c" = 200 ]; then
      ok "本机网关响应正常（HTTP $_c）"
    elif [ -n "$_c" ]; then
      warn "本机网关返回 HTTP $_c（预期 200）"
    else
      warn "已核验回环监听，但网关未在时限内返回 HTTP 响应"
    fi ;;
  *) warn "未核验到明确归属的回环监听，跳过本机 HTTP 探测" ;;
esac

echo "[4/10] 面板与访问密码"
if [ -s "$magpie_path/data/web.key" ]; then
  ok "访问密码存在（未读取或发送）"
else
  warn "没有 data/web.key" "首次启动服务时会自动生成"
fi
case "$_web_bind" in
  'local '*) ok "已核验面板回环监听；未发送或验证访问密码" ;;
  *) warn "未核验到本模块的面板回环监听，不建议在未核实的页面输入密码" ;;
esac

# [执行] → 6 实际走的路径：控制器 panel-url → am 交给浏览器。只解析、不真正启动，
# 避免 doctor 弹出浏览器；不带密码。之前只测端口，路径断了也全绿。
_purl=$(MAGPIE_CONF="$CONF" sh "$MODDIR/scripts/magpie.service" panel-url 2>/dev/null) || _purl=''
if [ -z "$_purl" ]; then
  warn "[执行]→6 拿不到控制器核验的面板地址，打不开面板" "服务未运行，或面板监听未能核验"
elif ! command -v cmd >/dev/null 2>&1; then
  bad "[执行]→6 找不到 cmd（am 依赖它），无法把地址交给浏览器" "PATH=$PATH"
else
  _res=$(cmd package resolve-activity --brief -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE -d "$_purl" </dev/null 2>&1)
  case "$_res" in
    *'Failed transaction'*|*Exception*|*Failure*)
      bad "[执行]→6 本 shell 调不通系统服务：$(printf '%s' "$_res" | tail -n 1)" \
        "多见于 KernelSU 的 SELinux 规则；[执行] 会把这条错误原样显示" ;;
    *'No activity found'*) bad "[执行]→6 没有能打开 $_purl 的浏览器" "安装或启用一个浏览器" ;;
    */*) ok "[执行]→6 可交给 $(printf '%s' "$_res" | tail -n 1 | cut -d/ -f1) 打开 $_purl（仅解析，未启动）" ;;
    *) warn "[执行]→6 无法确认浏览器解析结果" "$(printf '%s' "$_res" | tail -n 1)" ;;
  esac
fi

echo "[5/10] 网关密钥"
if [ -x "$magpie_path/bin/magpie" ]; then
  _n=$(HOME="$magpie_path/data" MAGPIE_HOME="$magpie_path/data" \
       timeout 15 "$magpie_path/bin/magpie" gateway-key list 2>/dev/null \
       | grep -c 'enabled')
  if [ "$_n" -gt 0 ] 2>/dev/null; then
    ok "有 $_n 把已启用的网关密钥"
  else
    warn "没有已启用的网关密钥" "局域网访问需要它：magpie gateway-key add phone"
  fi
fi

echo "[6/10] CA 证书包"
CA="$magpie_path/data/certs/ca-bundle.crt"
if [ -s "$CA" ]; then
  _n=$(grep -c 'BEGIN CERTIFICATE' "$CA" 2>/dev/null)
  if [ "${_n:-0}" -gt 0 ] 2>/dev/null; then
    ok "证书包包含 $_n 个证书头（权限 $(stat -c %a "$CA" 2>/dev/null)）"
  else
    warn "证书包非空但未找到可读的 PEM 证书头" "检查 data/certs/ca-bundle.crt 后重新生成"
  fi
else
  warn "没有证书包" "重启服务会自动生成；HTTPS 若失败可删掉它再重启"
fi

echo "[7/10] 局域网暴露"
report_scope 网关 "$MAGPIE_ADDR" "$_api_bind"
report_scope 面板 "$WEB_ADDR" "$_web_bind"

echo "[8/10] DNS 解析"
DL_BB=''
for _b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
  [ -x "$_b" ] && { DL_BB="$_b"; break; }
done
# magpie 是不链接 libc 的 Go 静态 PIE，解析域名只走 /etc/resolv.conf。
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
    | awk '/^Name:/{f=1;next} f && /^Address( [0-9]+)?: /{sub(/^Address( [0-9]+)?: /,""); print $1}' | head -1)
  if [ -n "$_addr" ]; then
    ok "上游 $_srv 能解析 api.deepseek.com（$_addr）"
  else
    warn "上游 $_srv 解析 api.deepseek.com 失败" "换一个 MAGPIE_DNS（如 223.5.5.5）后重启服务"
  fi
fi

echo "[9/10] 磁贴（可选组件）"
# 取数与判定都用 scripts/tile-check.sh，磁贴 App 的「自查」按钮跑的是同一个脚本，
# 这样两边不可能出现「doctor 说没事、App 说被冻了」。
_tc_sh="$MODDIR/scripts/tile-check.sh"
_tc=""; _tc_rc=1
if [ -f "$_tc_sh" ]; then
  _tc=$(sh "$_tc_sh" 2>/dev/null)
  _tc_rc=$?
fi
# 缺字段或重复字段均无有效值；不能挑冲突输出中的第一条当作成功。
tcget() {
  [ "$(printf '%s\n' "$_tc" | grep -c "^$1=")" = 1 ] || return 1
  printf '%s\n' "$_tc" | sed -n "s/^$1=//p"
}

# done=1 必须唯一且位于最后。执行失败、旧脚本、截断/部分输出都不作健康结论。
_tc_complete=1
if [ "$_tc_rc" != 0 ] || [ "$(tcget 'done')" != 1 ] ||
   [ "$(printf '%s\n' "$_tc" | tail -1)" != done=1 ]; then
  _tc_complete=0
fi
for _tk in mod svc installed; do
  tcget "$_tk" >/dev/null || _tc_complete=0
done
_tinst=$(tcget installed)
if [ "$_tinst" = 1 ]; then
  for _tk in uid vcode magisk inqs painted alive frozen freezer; do
    tcget "$_tk" >/dev/null || _tc_complete=0
  done
fi

if [ "$_tc_complete" != 1 ]; then
  warn "磁贴检查未完成，本次结果未知（可选组件，不影响网关）" \
    "检查 tile-check.sh 是否为新版后重试；失败或部分输出不能证明未安装、已停止或被冻结"
else
  case "$(tcget mod)" in
    0) bad "没找到 magpie 模块" "磁贴要靠模块里的脚本启停，先刷入模块" ;;
    1) : ;;
    *) warn "模块安装状态未知，无法确认模块目录" ;;
  esac
  case "$_tinst" in
    0) ok "未安装磁贴 App（可选组件，不影响网关）" ;;
    1)
      _tuid=$(tcget uid)
      ok "已安装磁贴 App（versionCode $(tcget vcode)，UID ${_tuid:-?}）"

      # unknown 包含非 Magisk 与查询失败；不等于 root 被拒或尚未授权。
      case "$(tcget magisk)" in
        2) ok "Magisk 里已允许 root" ;;
        1) bad "Magisk 里 root 被拒绝" "Magisk → 超级用户，把 Magpie 磁贴改成允许" ;;
        0) warn "Magisk 里 root 尚未授权" "点一次磁贴并在弹窗里允许" ;;
        *) warn "root 授权状态未知（非 Magisk 或查询不可用），不据此判断授权被拒" ;;
      esac

      case "$(tcget inqs)" in
        0) ok "未加入控制中心（不影响网关；需要时在编辑里拖进去）" ;;
        1)
          _tpaint=$(tcget painted)
          case "$_tpaint" in
            unknown) warn "磁贴绘制状态未知，无法读取控制中心状态" ;;
            null|'') warn "磁贴还没画出状态" "展开一次控制中心让它刷新" ;;
            处理中*) ok "磁贴正在刷新（处理中，属瞬态）" ;;
            需要\ root) warn "磁贴显示「需要 root」" "看上一条 root 授权是否被拒或撤销" ;;
            模块未安装) bad "磁贴显示「模块未安装」" "确认模块目录存在：$MODDIR" ;;
            *)
              _expect=""
              case "$(tcget svc)" in
                running) _expect=运行中 ;;
                stopped) _expect=已停止 ;;
              esac
              if [ -z "$_expect" ]; then
                warn "服务状态未知，无法确认磁贴显示「$_tpaint」是否与实际一致"
              elif [ "$_tpaint" = "$_expect" ]; then
                ok "磁贴显示「$_tpaint」，与实际一致"
              else
                warn "磁贴显示「$_tpaint」，实际是「$_expect」" \
                  "服务被命令行或看门狗启停过、磁贴还没重读；展开一次控制中心就会对齐。若展开后仍不对，看下面的冻结检查"
              fi
              ;;
          esac
          ;;
        *) warn "是否加入控制中心未知，无法确认磁贴位置" ;;
      esac

      # 只有两个确定的计数才可判断冻结；unknown 不能冒充 0 或正数。
      _talive=$(tcget alive)
      _tfrozen=$(tcget frozen)
      _tcounts=1
      case "$_talive" in ''|*[!0-9]*) _tcounts=0 ;; esac
      case "$_tfrozen" in ''|*[!0-9]*) _tcounts=0 ;; esac
      if [ "$_talive" = 0 ]; then
        ok "进程当前未运行（展开面板时会自动拉起，不需要常驻）"
      elif [ "$_tcounts" != 1 ]; then
        warn "进程或冻结状态未知，无法确认是否被冻结"
      elif [ "$_tfrozen" -gt "$_talive" ] 2>/dev/null; then
        warn "进程与冻结计数不一致，本次冻结状态未知"
      elif [ "$_tfrozen" = 0 ]; then
        ok "进程未被冻结（$_talive 个进程全部可运行）"
      else
        _who=$(tcget freezer)
        case "$_who" in
          NoActive) _wname="NoActive" ;;
          CZero) _wname="CZero" ;;
          system) _wname="系统 cached_apps_freezer" ;;
          greezer) _wname="HyperOS greezer" ;;
          *) _wname="" ;;
        esac
        warn "进程被冻结（$_tfrozen/$_talive 个），磁贴会停在上一帧" \
          "冻结期间展开面板读不到状态，不是逻辑错误。${_wname:+疑似 $_wname 在冻；}把本 App 的 UID $_tuid 加入它的白名单（App 自己躲不掉）"
      fi
      ;;
    *) warn "磁贴 App 安装状态未知（可选组件，不影响网关），不能判断为未安装" ;;
  esac
fi

echo "[10/10] 日志与磁盘"
for _f in "$magpie_path/run/magpie.log" "$magpie_path/run/watchdog.log"; do
  if [ -f "$_f" ]; then
    _sz=$(stat -c %s "$_f" 2>/dev/null)
    _mb=$((_sz / 1048576))
    if [ "$_sz" -gt 5242880 ] 2>/dev/null; then
      warn "${_f##*/} 已 $_mb MB" "超过 5 MB，看门狗下一轮会归档为 .1"
    else
      ok "${_f##*/} $_mb MB"
    fi
  fi
done
if [ ! -d "$magpie_path/data" ]; then
  warn "数据目录尚未创建" "首次启动服务时自动生成"
elif [ -w "$magpie_path/data" ] && [ -x "$magpie_path/data" ]; then
  ok "数据目录的访问检查允许写入（未创建测试文件）"
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
