# customize.sh —— 刷入时由 Magisk / KernelSU / APatch 调用
# 只做权限与依赖检查，不改动模块文件内容，也不联网下载
# （刷入流程里没有可靠的交互终端，91MB 的下载放到模块装好之后由用户确认触发）

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
MAGPIE_BIN=/data/adb/magpie/bin/magpie
if [ -x "$MAGPIE_BIN" ]; then
  _ver=$(HOME=/data/adb/magpie/data "$MAGPIE_BIN" --version 2>/dev/null | head -1)
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
