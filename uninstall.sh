#!/system/bin/sh
# Magpie for Android - 卸载：停服务并移除模块自有产物；默认保留配置和用户数据

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 1

# 数据目录跟着配置走。卸载模块默认保留上游本体、配置、密钥、证书、用量记录和日志。
[ -f "$MODDIR/scripts/lib.sh" ] && . "$MODDIR/scripts/lib.sh" 2>/dev/null
command -v magpie_resolve_conf >/dev/null 2>&1 || magpie_resolve_conf() { return 1; }
magpie_path=/data/adb/magpie
_CONF=$(magpie_resolve_conf "$MODDIR" 2>/dev/null)
[ -n "$_CONF" ] && sh -n "$_CONF" >/dev/null 2>&1 && . "$_CONF" 2>/dev/null
DATA=${magpie_path:-/data/adb/magpie}

if ! command -v magpie_path_in_module_tree >/dev/null 2>&1; then
  echo "! 缺少路径核验工具，卸载脚本不执行清理"
  exit 1
fi
_DATA_IN_MODULE=0
if [ -d "$DATA" ] && magpie_path_in_module_tree "$DATA" "$MODDIR"; then
  _DATA_IN_MODULE=1
  echo "! 用户数据位于可被管理器删除的模块目录：$DATA"
  echo "! 不能保证数据保留；请在移除模块前备份并迁移至 /data/adb/magpie。"
fi

# 管理器不看本脚本的退出码，失败后照样删掉模块目录。所以无论成败都要清掉
# 指向模块的 PATH 链接（否则留下一个指向已删除脚本的 magpie 命令）。
# 只删指向本模块的软链接，不碰同名的其它文件。
remove_cli_links() {
  for _p in /data/adb/ksu/bin /data/adb/magisk /data/adb/ap/bin; do
    [ -L "$_p/magpie" ] || continue
    case "$(readlink "$_p/magpie" 2>/dev/null)" in
      "$MODDIR/scripts/magpie-cli.sh"|/data/adb/modules/magpie/scripts/magpie-cli.sh) rm -f "$_p/magpie" 2>/dev/null && echo "- 已移除 $_p/magpie" ;;
    esac
  done
}
trap remove_cli_links EXIT

# 先立标记，service.sh 看门狗和 magpie.service 的新 start 都会拒绝恢复。
: > "$MODDIR/.uninstalling" 2>/dev/null || { echo "! 无法创建卸载维护标记，停止卸载"; exit 1; }

# 1) 正常停服务。不能确认停净时立刻失败关闭，不继续清理或删除数据。
if [ ! -f "$MODDIR/scripts/magpie.service" ]; then
  echo "! 找不到服务控制器，无法确认服务已停止；保留所有数据并中止卸载"
  exit 1
fi
sh "$MODDIR/scripts/magpie.service" stop >/dev/null 2>&1
_STOP_RC=$?
if [ "$_STOP_RC" -ne 0 ]; then
  echo "! 服务停止失败（退出码 $_STOP_RC）；保留用户数据并中止清理"
  exit 1
fi
if command -v magpie_command_pids >/dev/null 2>&1; then
  _LEFT_SERVE=$(magpie_command_pids serve 2>/dev/null)
  _LEFT_MCP=$(magpie_mcp_pids 2>/dev/null)
else
  echo "! 无法验证服务进程身份；保留用户数据并中止清理"
  exit 1
fi
if [ -n "$_LEFT_SERVE$_LEFT_MCP" ]; then
  echo "! 服务仍有残留进程（serve: ${_LEFT_SERVE:-无}; mcp: ${_LEFT_MCP:-无}）；保留用户数据并中止清理"
  exit 1
fi

if [ "$_DATA_IN_MODULE" = 1 ]; then
  echo "! 已停止服务；为避免误报数据已保留，不继续清理。"
  exit 1
fi

# 看门狗按模块目录身份和 .uninstalling 自行退出。无需枚举 /proc，更不能
# 仅凭命令行里提过 service.sh 路径就发信号（编辑器、日志工具也可能提到它）。

# 3.5) 顺手卸掉磁贴 App（它只是本模块的配件，留着没有意义）。
#
# 不依赖 scripts/tile-app.sh：从管理器「移除模块」时，模块目录已经先被删了，
# 那时读不到那个脚本。这里直接按包名卸，一个包名而已，不需要 helper。
# （包名与 tile-app/AndroidManifest.xml 里的 package 必须一致。）
if command -v pm >/dev/null 2>&1; then
  if pm uninstall com.ruin.magpie.tile >/dev/null 2>&1; then
    echo "- 已卸载磁贴 App"
  fi
fi

# 旧 DNS 辅助进程已由持锁的控制器核验；不要在卸载器中另用一套宽松判据。
echo "- Magpie 服务已停止"

# 5) PATH 里的 magpie 命令由 EXIT trap（remove_cli_links）清理

# 6) 用户数据默认保留。包括上游本体、配置、供应商、网关 key、用量记录、证书和日志。
if [ -d "$DATA" ]; then
  echo "- 卸载脚本未删除用户数据：$DATA（如需清除，请先备份并手动核对路径）"
fi
[ "$DATA" = "/data/adb/magpie" ] || [ ! -d "/data/adb/magpie" ] || \
  echo "- 卸载脚本未删除旧默认数据：/data/adb/magpie"

# 7) 移除模块生成的快照和日志尾（旧版快照可能包含凭据）
rm -f "$MODDIR/webroot/status.json" "$MODDIR/webroot/lastlog.txt" 2>/dev/null

# 8) 复查
_left=""
pidof magpie >/dev/null 2>&1 && _left="$_left magpie进程"
if [ -n "$_left" ]; then
  echo "- 模块已清理，但仍有进程需人工检查:$_left"
else
  echo "- 模块卸载脚本清理完成；未删除用户数据"
fi
