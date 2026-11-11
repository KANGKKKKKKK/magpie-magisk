# Magpie AI 网关 · Android 模块

把 magpie 模型网关跑成 Android 上的常驻服务：开机自启、进程守护、WebUI 面板、CA 证书自动更新。

> **本仓库只包含模块脚本，不含 magpie 本体**（arm64 二进制约 74 MB）。模块假定 magpie 已经装在 `/data/adb/magpie`。

作者：可樂

## 功能

| 能力 | 说明 |
| --- | --- |
| 开机自启 | `service.sh` 等 `sys.boot_completed` 后拉起，不阻塞开机流程 |
| 进程守护 | 20 秒巡检，被杀或被系统回收后自动重新拉起；用户主动停止时不会强行恢复 |
| 一键启停 | 管理器里点 `[执行]`：未运行则启动并打开 WebUI，已在运行则停止 |
| 状态面板 | 生成 `webroot/status.json` 与 `lastlog.txt`，供模块 WebUI 直接读取 |
| 状态描述 | 管理器列表里的模块描述实时显示「运行中 / 已停止」和 magpie 版本号 |
| 命令行 | `magpie` 命令自动注入 PATH，并补齐 `HOME`、`SSL_CERT_FILE`、`MAGPIE_BUN`、上游 DNS |
| CA 证书 | 合并系统根证书供静态编译的 Go 使用，系统 CA 变化时自动重建 |
| 日志轮转 | 超过 5 MB 归档为 `.1`，只留一份，不会无限堆积 |
| 彻底卸载 | 停服务、收掉守护进程、清 PATH 链接、删除整个数据目录 |

## 环境要求

- Magisk v20.4+、KernelSU 或 APatch
- arm64 Android（magpie 本体为 arm64 ELF）
- magpie 本体已安装在 `/data/adb/magpie`
  - 二进制：`/data/adb/magpie/bin/magpie`
  - 数据目录：`/data/adb/magpie/data`（配置、供应商、网关 key、Bun 缓存都在这里）

## 安装

### 方式一：刷入 zip

1. 准备 magpie 本体，放到 `/data/adb/magpie/bin/magpie` 并 `chmod 755`。
2. 从 [Releases](../../releases) 下载 `magpie-v0.5.zip`。
3. 管理器 → 模块 → 从本地安装 → 选 zip → 重启。

刷入时 `customize.sh` 会设置好权限，并检查 magpie 本体是否存在；缺失只会提示，不会中断安装。

### 方式二：手动放置

```sh
unzip magpie-v0.5.zip -d /data/adb/modules/magpie
chmod 755 /data/adb/modules/magpie/*.sh /data/adb/modules/magpie/scripts/*.sh
chmod 600 /data/adb/modules/magpie/scripts/magpie.config
```

重启，或在管理器里点一次 `[执行]`。

## 使用

### 执行按钮

管理器模块页的 `[执行]` 是开关：

- 服务没跑 → 启动，然后直接打开带密钥的 WebUI
- 服务在跑 → 停止（会写 `.user_stopped` 标记，看门狗不会马上又拉起来）

### WebUI

默认 `http://127.0.0.1:3430/?k=<密钥>`。密钥固定在 `/data/adb/magpie/data/web.key`，重启不变；不带 `?k=` 会返回 401。

面板可看：运行状态、版本、二进制大小、运行时长、内存占用、网关地址、WebUI 地址、局域网地址、网关 key、日志尾。

### 命令行

```sh
su -c magpie --version            # magpie 0.1.3620
su -c magpie gateway-key list     # 列网关 key
su -c sh /data/adb/modules/magpie/scripts/magpie.service status
```

`magpie` 命令由 `scripts/magpie-cli.sh` 包装，自动处理 Android 上缺的环境变量，可直接当官方 CLI 用。

### 服务控制

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service start
su -c sh /data/adb/modules/magpie/scripts/magpie.service stop
su -c sh /data/adb/modules/magpie/scripts/magpie.service restart
su -c sh /data/adb/modules/magpie/scripts/magpie.service status
```

`start` 失败时返回非 0，日志在 `/data/adb/magpie/run/magpie.log`。

## 配置

`scripts/magpie.config`（同时会同步一份到 `/data/adb/magpie/scripts/magpie.config`，以数据目录里的为准）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `magpie_path` | `/data/adb/magpie` | 数据目录，二进制 / 日志 / magpie 自身数据都在里面 |
| `MAGPIE_ADDR` | `127.0.0.1:3425` | API 网关监听地址。只监听本机；要开放给局域网改成 `0.0.0.0:3425` |
| `MAGPIE_WEB_ADDR` | `127.0.0.1:3430` | WebUI 监听地址。留空则自动用 `MAGPIE_ADDR` 的 host + 3430 |
| `MAGPIE_DNS` | `223.5.5.5 119.29.29.29 8.8.8.8` | 上游 DNS，空格分隔 |

改完重启服务生效：

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service restart
```

配置文件缺失时脚本使用内置默认值，且默认全部监听 `127.0.0.1`，不会意外把自己暴露到局域网。

## 文件结构

```
magpie-magisk/
├── module.prop                       模块信息（名字、版本、作者、描述）
├── customize.sh                      刷入时执行：设权限、查本体
├── service.sh                        开机自启 + 看门狗
├── action.sh                         管理器 [执行] 按钮
├── uninstall.sh                      卸载清理
├── scripts/
│   ├── magpie.service                start / stop / restart / status
│   ├── status.sh                     生成状态描述、status.json、日志尾
│   ├── magpie-cli.sh                 补环境变量后调用 magpie 本体
│   └── magpie.config                 配置
├── webroot/
│   └── index.html                    模块 WebUI 面板
└── META-INF/com/google/android/      Magisk 刷机脚本
```

运行时会生成、不进仓库的文件：

```
/data/adb/magpie/run/magpie.log        服务日志
/data/adb/magpie/run/watchdog.log      看门狗日志
/data/adb/magpie/run/.user_stopped     用户主动停止的标记
/data/adb/magpie/run/magpie.pid        PID 文件
/data/adb/magpie/data/certs/           CA 证书包与指纹
webroot/status.json                    面板状态（含密钥，权限 600）
webroot/lastlog.txt                    面板日志尾（权限 600）
```

## 工作方式

三个入口，逻辑都在 `scripts/`：

- **`service.sh`**：开机后等 `sys.boot_completed=1`，归档日志、启动服务、刷新状态；另外常驻一个 20 秒巡检的看门狗，发现进程没了就重新拉起。看门狗在模块被禁用、正在卸载或目录被删时自行退出。
- **`action.sh`**：读 PID 判断当前状态，停止后等进程真的退出再报结果，启动后等端口就绪再开网页；两条路径都刷新模块描述。
- **`scripts/magpie.service`**：真正的服务控制。启动前清理 v0.2 遗留的 dnsmasq、注入环境变量、拉起 `magpie serve --web=<addr>`、写入 PID 与 WebUI 链接。

两个细节：

- **DNS 不占 53 端口**。静态 Go 在 Android 上没有 `/etc/resolv.conf`，会退回查 `::1:53`。本模块用 Go 官方的 `DNS_LOCAL_HOSTNAMES` 直连公网 DNS，不启动本地 dnsmasq，因此不会和系统热点的 dnsmasq 抢端口。
- **CA 证书会自己更新**。给系统证书目录算指纹（文件数 + 目录 mtime，`/system/etc/security/cacerts` 与 APEX 那份一起算），存在 `ca-bundle.crt.stamp`；启动服务和调用 `magpie` 命令时比对，不一致就重建。重建先写临时文件、校验有证书才原子替换，失败则保留旧包。

## 排障

| 现象 | 处理 |
| --- | --- |
| 启动失败，日志提示端口占用 | 上一次进程没退干净，`pidof magpie` 确认后 kill，再 `start` |
| 打开 WebUI 是 401 | 链接少了 `?k=`，从管理器点 `[执行]` 打开，或读 `/data/adb/magpie/data/web.key` |
| 面板数据一动不动 | 属预期：面板读的是启停那一刻的快照 |
| 局域网连不上 | 把 `MAGPIE_ADDR` / `MAGPIE_WEB_ADDR` 改成 `0.0.0.0:<端口>`，重启服务 |
| HTTPS 请求报证书错误 | 删掉 `/data/adb/magpie/data/certs/ca-bundle.crt*` 再重启服务，会自动重建 |
| 服务停止后自己又起来了 | 检查 `run/.user_stopped` 是否存在；`stop` 会写这个标记 |

## 已知限制

- WebUI 面板的运行时长、内存、日志尾是**启停时的快照**，不会随时间刷新。
- 不含 magpie 本体；本体更新由 magpie 自己负责，模块只负责调度。
- 只在 arm64 设备、Android 14（HyperOS 2.0）上实测过；理论上 Android 10+ 的 arm64 设备都适用。
- 旧版 dnsmasq 清理只针对 `listen-address=::1` 的老进程，不会碰系统热点的 dnsmasq。

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。

## 说明

- 本仓库的脚本按现状提供，不附带任何担保；刷模块前请自行确认设备有可用的救砖手段。
- magpie 本体是第三方软件，版权归其作者所有，本仓库不再分发。
