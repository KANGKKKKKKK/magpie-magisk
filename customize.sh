# customize.sh —— 刷入时由 Magisk / KernelSU / APatch 调用
# 只做权限与依赖检查，不改动模块文件内容，也不联网下载
# （刷入流程里没有可靠的交互终端，87 MB 的下载放到模块装好之后由用户确认触发）

ui_print "*******************************"
ui_print "  Magpie AI 网关 · Android 模块"
ui_print "*******************************"

# 目录 755，文件默认 644
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in action.sh service.sh uninstall.sh customize.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/scripts/magpie.config" 0 0 0600

# 本模块只负责调度，不含 magpie 本体
# 路径按配置读，自定义过 magpie_path 的用户也能看到正确的结果
_CONF="${MAGPIE_CONF:-/data/adb/magpie/scripts/magpie.config}"
[ -f "$_CONF" ] || _CONF="$MODPATH/scripts/magpie.config"
[ -f "$_CONF" ] && . "$_CONF" 2>/dev/null
magpie_path=${magpie_path:-/data/adb/magpie}

# DNS：magpie 是不链接 libc 的 Go 静态 PIE，只认 /etc/resolv.conf。
# 这里按 MAGPIE_DNS 生成模块覆盖，开机后由 Magisk 挂成 /etc/resolv.conf；
# 老版本注入的 DNS_LOCAL_HOSTNAMES 是无效的（Go 与 magpie 都不读）。
_RESOLV="$MODPATH/system/etc/resolv.conf"
if [ -n "${MAGPIE_DNS:-}" ]; then
  # 校验只用 lib.sh 那一份：刷入时 lib.sh 一定在包里。
  # 不在这里另写一套弱校验——看起来校验过、实际漏判，比明说没校验更坑。
  # shellcheck disable=SC1090
  [ -f "$MODPATH/scripts/lib.sh" ] && . "$MODPATH/scripts/lib.sh" 2>/dev/null
  command -v is_ip_addr >/dev/null 2>&1 || is_ip_addr() { [ -n "$1" ]; }

  mkdir -p "$MODPATH/system/etc"
  # 先写临时文件、确认里面真有 nameserver 再替换：
  # 配置写错时保留模块自带那份，别把能用的 DNS 覆盖成空的。
  _RESOLV_NEW="$_RESOLV.new"
  : > "$_RESOLV_NEW"
  _DNS_BAD=""
  for _ns in $MAGPIE_DNS; do
    if is_ip_addr "$_ns"; then
      echo "nameserver $_ns" >> "$_RESOLV_NEW"
    else
      _DNS_BAD="$_DNS_BAD $_ns"
    fi
  done
  echo "options timeout:2 attempts:2" >> "$_RESOLV_NEW"
  _DNS_BAD=${_DNS_BAD# }
  if grep -q '^nameserver ' "$_RESOLV_NEW" 2>/dev/null; then
    mv -f "$_RESOLV_NEW" "$_RESOLV" 2>/dev/null
    set_perm "$MODPATH/system/etc" 0 0 0755
    set_perm "$_RESOLV" 0 0 0644
    ui_print "- 上游 DNS：$MAGPIE_DNS（写入 /etc/resolv.conf 覆盖）"
    [ -n "$_DNS_BAD" ] && ui_print "! 这些项不是合法地址，已跳过：$_DNS_BAD"
  else
    rm -f "$_RESOLV_NEW" 2>/dev/null
    ui_print "! MAGPIE_DNS 里没有有效的 DNS 地址，保留模块自带的 /etc/resolv.conf"
  fi
fi
MAGPIE_BIN="$magpie_path/bin/magpie"
if [ -x "$MAGPIE_BIN" ]; then
  _ver=$(HOME="$magpie_path/data" "$MAGPIE_BIN" --version 2>/dev/null | head -1)
  if [ -n "$_ver" ]; then
    ui_print "- 已检测到本体：$_ver"
    ui_print "- 不会覆盖它；升级请用 su -c magpie update"
  else
    ui_print "! 本体存在但跑不起来：$MAGPIE_BIN"
    ui_print "! 可在管理器点 [执行] 重装"
  fi
else
  ui_print "- 尚未安装 magpie 本体（本模块不含本体）"
  ui_print "  安装方式：管理器点 [执行]，或执行"
  ui_print "    su -c sh /data/adb/modules/magpie/scripts/install.sh install --yes"
  ui_print "  本体就位前看门狗不会反复尝试启动"
fi

ui_print "- 开机后自动启动；管理器里点 [执行] 可启停"
