# customize.sh —— 刷入时由 Magisk / KernelSU / APatch 调用
# 只做权限与依赖检查，不改动模块文件内容

ui_print "*******************************"
ui_print "  Magpie AI 网关 · Android 模块"
ui_print "  by 可樂"
ui_print "*******************************"

# 目录 755，文件默认 644
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in action.sh service.sh uninstall.sh customize.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/scripts/magpie.config" 0 0 0600

# 本模块只负责调度，不含 magpie 本体
if [ -x /data/adb/magpie/bin/magpie ]; then
  _ver=$(HOME=/data/adb/magpie/data /data/adb/magpie/bin/magpie --version 2>/dev/null | head -1)
  ui_print "- 已检测到 magpie 本体${_ver:+: $_ver}"
else
  ui_print "! 未找到 /data/adb/magpie/bin/magpie"
  ui_print "! 本模块不含 magpie 本体，请先安装 magpie，再重启"
fi

ui_print "- 开机后自动启动；管理器里点 [执行] 可启停"
