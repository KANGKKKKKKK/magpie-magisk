# 变更记录

## v0.5 — 2026-11-11

### 修复

- **配置缺失会崩**：`magpie.service` 原来无条件 source `magpie.config`，文件不在时 `magpie_path` 为空，`BIN` 变成 `/bin/magpie`，启动必然失败。现在脚本内置默认值兜底。
- **默认地址 fail-open**：三处兜底值原本是 `0.0.0.0:3425`，配置一丢网关就监听到局域网。统一改为 `127.0.0.1:3425`。
- **看门狗日志只归档不重建**：`watchdog.log` 超 5 MB 时只做了 `mv`，既不重建文件也不设权限。现在统一走 `rotate_log()`。
- **启动固定等 2 秒**：设备慢时容易误报启动失败。改为每 0.5 秒轮询 PID，最多 6 秒。
- **`start` 失败仍返回 0**：`magpie.service` 的 case 分支用 `sync_status` 的退出码覆盖了 `start` 的结果，脚本无法感知失败。现在把 `start` 的返回值带出来。
- **面板日志可被其它应用读取**：`webroot/lastlog.txt` 原来是 666，改为 600，与 `status.json` 一致。
- **卸载收不掉看门狗**：`uninstall.sh` 只杀 magpie 进程，`service.sh` 里的守护子 shell 还活着，20 秒后会把服务重新拉起。现在卸载前先写 `.uninstalling` 标记让守护自行退出，再按命令行精确匹配 `service.sh` 收尾。
- **卸载不彻底**：数据目录、PATH 链接、插件宿主 `magpie-bun` 进程、面板文件都没清。现在逐项清理并复查残留。

### 新增

- **CA 证书自动更新**：按系统证书目录指纹判断是否需要重建，先写临时文件校验后原子替换，重建失败保留旧包。
- **证书来源补全**：同时读取 `/system/etc/security/cacerts` 与 APEX 的 `/apex/com.android.conscrypt/cacerts`，按文件名去重。
- **可刷入 zip**：新增 `customize.sh` 与 `META-INF/`，支持管理器直接刷入。
- **日志带日期**：服务日志时间戳由 `HH:MM:SS` 改为 `YYYY-MM-DD HH:MM:SS`。
- **开机启动日志保留**：开机拉起服务的输出改为写入看门狗日志，不再丢弃。

### 变更

- 脚本注释精简（注释行 142 → 65），逻辑不变。
- 模块版本 `v0.4` → `v0.5`，`versionCode` 1004 → 1005。

## v0.4 及更早

模块内部版本，未单独记录。
