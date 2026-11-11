# Magpie AI 网关 · Android 模块

把 [magpie](https://github.com/yetone/magpie) 变成 Android 上的常驻服务：开机自己起来，被杀自己回来，一个按钮启停。

> 本仓库只含模块脚本，**不含 magpie 本体**（arm64 二进制约 74 MB）。模块假定 magpie 已装在 `/data/adb/magpie`。

## 为什么需要它

[magpie](https://github.com/yetone/magpie) 是为桌面写的 Go 程序。搬到手机上能跑，但会连续撞上四件事：

- **DNS 查不到**。Go 找不到 `/etc/resolv.conf`，退回查 `::1:53`，日志里刷 `connection refused`。
- **HTTPS 全挂**。Go 只认 `/etc/ssl/certs/ca-certificates.crt` 这类固定路径，Android 上一个都没有——它的证书是 `/system/etc/security/cacerts/<hash>.0`，一证书一文件。
- **开机不自启**。Android 没有 systemd，重启之后得手动再起一次。
- **被杀就没了**。清理类 App、内存回收、系统「一键清理」都能直接 kill 掉它，而它自己不会回来。对下游客户端来说，这等于出口断了。

这个模块补上前三件，用看门狗解决第四件，并附一套能看见状态、能收拾干净的周边。

## 能做什么

| 能力 | 说明 |
| --- | --- |
| 开机自启 | 等 `sys.boot_completed` 后拉起，不阻塞开机 |
| 进程守护 | 20 秒巡检，被杀或回收后自动拉回；用户主动停止时不强行恢复 |
| 一键启停 | 点 `[执行]`：没跑就启动并打开 WebUI，在跑就停止 |
| 状态可见 | 管理器描述实时显示「运行中 / 已停止」+ magpie 版本号 |
| 网页面板 | 状态、PID、接口地址、API Key、局域网地址、访问密码、日志尾 |
| 命令行 | `magpie` 自动进 PATH，补齐 `HOME`、`SSL_CERT_FILE`、`MAGPIE_BUN`、上游 DNS |
| CA 证书 | 合并系统根证书供静态 Go 使用，系统 CA 变化时自动重建 |
| 日志轮转 | 超过 5 MB 归档为 `.1`，只留一份 |
| 彻底卸载 | 停服务、收守护进程、清 PATH 链接、删数据目录，并复查残留 |

## 快速开始

1. 把 magpie 本体放到 `/data/adb/magpie/bin/magpie`，`chmod 755`。
2. 从 [Releases](https://github.com/KANGKKKKKKK/magpie-magisk/releases) 下载 `magpie-v0.5.zip`，在管理器里从本地安装。
3. 重启。

验证：

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service status
# running (PID 5523)
```

刷入时 `customize.sh` 会设好权限并检查本体；本体缺失只提示，不中断安装。

不想刷 zip 也可以手动放置：

```sh
unzip magpie-v0.5.zip -d /data/adb/modules/magpie
chmod 755 /data/adb/modules/magpie/*.sh /data/adb/modules/magpie/scripts/*.sh
chmod 600 /data/adb/modules/magpie/scripts/magpie.config
```

## 日常使用

### 执行按钮

管理器模块页的 `[执行]` 是开关：

- 服务没跑 → 启动，然后直接打开带密钥的 WebUI
- 服务在跑 → 停止（写 `.user_stopped` 标记，看门狗不会马上又拉起来）

### 网页面板

默认 `http://127.0.0.1:3430/?k=<密钥>`。密钥固定在 `/data/adb/magpie/data/web.key`，重启不变；不带 `?k=` 返回 401。

面板显示：运行状态与 PID、OpenAI 兼容接口地址、API Key、局域网地址、WebUI 访问地址与密码、日志尾。

`status.json` 里另有 `version`、`binSize`、`uptime`、`mem` 等字段，面板暂未渲染，需要时可以直接读或用脚本取。

### 命令行

```sh
su -c magpie --version            # magpie 0.1.3620
su -c magpie gateway-key list     # 列网关 key
```

`magpie` 由 `scripts/magpie-cli.sh` 包装，自动处理 Android 上缺的环境变量，用法与官方 CLI 一致。

### 服务控制

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service start
su -c sh /data/adb/modules/magpie/scripts/magpie.service stop
su -c sh /data/adb/modules/magpie/scripts/magpie.service restart
su -c sh /data/adb/modules/magpie/scripts/magpie.service status
```

`start` 失败返回非 0，日志在 `/data/adb/magpie/run/magpie.log`。

## 配置

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `magpie_path` | `/data/adb/magpie` | 数据目录，二进制 / 日志 / magpie 自身数据都在里面 |
| `MAGPIE_ADDR` | `127.0.0.1:3425` | API 网关监听地址 |
| `MAGPIE_WEB_ADDR` | `127.0.0.1:3430` | WebUI 监听地址；留空则用 `MAGPIE_ADDR` 的 host + 3430 |
| `MAGPIE_DNS` | `223.5.5.5 119.29.29.29 8.8.8.8` | 上游 DNS，空格分隔 |

脚本按顺序找配置文件：先 `/data/adb/magpie/scripts/magpie.config`，不存在才用模块里的 `scripts/magpie.config`。所以改配置请改**数据目录那份**，它不会被模块更新覆盖；两者都不在时使用内置默认值。

默认全部监听 `127.0.0.1`，只对本机开放。要让同一 Wi-Fi 下的其它设备访问，把 `MAGPIE_ADDR` / `MAGPIE_WEB_ADDR` 改成 `0.0.0.0:<端口>`——**注意此时网关对外可达，务必先建好网关 key**。

改完重启服务生效：

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service restart
```

## 工作原理

三个入口，逻辑都在 `scripts/`：

- **`service.sh`**：开机后等 `sys.boot_completed=1`，归档日志、启动服务、刷新状态；另外常驻一个 20 秒巡检的看门狗，发现进程没了就重新拉起。模块被禁用、正在卸载或目录被删时，看门狗自行退出。
- **`action.sh`**：读 PID 判断状态。停止后等进程真的退出才报结果，启动后等端口就绪才开网页；两条路径都刷新模块描述。
- **`scripts/magpie.service`**：真正的服务控制。启动前清理 v0.2 遗留的 dnsmasq、注入环境变量、拉起 `magpie serve --web=<addr>`、写 PID 与 WebUI 链接。

两个值得说的细节：

- **DNS 不占 53 端口**。用 Go 官方的 `DNS_LOCAL_HOSTNAMES` 直连公网 DNS，不启动本地 dnsmasq，因此不会和系统热点的 dnsmasq 抢端口——这是 v0.2 踩过的坑。
- **CA 证书自己更新**。给系统证书目录算指纹（文件数 + 目录 mtime，`/system/etc/security/cacerts` 与 APEX 那份一起算），存在 `ca-bundle.crt.stamp`；启动服务和调用 `magpie` 命令时比对，不一致就重建。先写临时文件、校验有证书才原子替换，失败保留旧包继续用。

  信任范围就是系统本来那些根证书：没有额外安装任何证书，没有中间人，也没有关掉校验。

## 文件结构

```
magpie-magisk/
├── module.prop                       模块信息（名字、版本、描述）
├── customize.sh                      刷入时执行：设权限、查本体
├── service.sh                        开机自启 + 看门狗
├── action.sh                         管理器 [执行] 按钮
├── uninstall.sh                      卸载清理
├── build.sh                          打包成可刷入的 zip
├── scripts/
│   ├── magpie.service                start / stop / restart / status
│   ├── status.sh                     生成状态描述、status.json、日志尾
│   ├── magpie-cli.sh                 补环境变量后调用 magpie 本体
│   └── magpie.config                 配置（默认值）
├── webroot/
│   └── index.html                    网页面板
└── META-INF/com/google/android/      Magisk 刷机脚本
```

运行时生成、不进仓库：

```
/data/adb/magpie/run/magpie.log        服务日志
/data/adb/magpie/run/watchdog.log      看门狗日志
/data/adb/magpie/run/.user_stopped     用户主动停止的标记
/data/adb/magpie/run/magpie.pid        PID 文件
/data/adb/magpie/data/certs/           CA 证书包与指纹
webroot/status.json                    面板数据（含密钥，权限 600）
webroot/lastlog.txt                    面板日志尾（权限 600）
```

## 排障

| 现象 | 处理 |
| --- | --- |
| 启动失败，日志说端口占用 | 上次进程没退干净，`pidof magpie` 确认后 kill，再 `start` |
| 打开面板是 401 | 链接少了 `?k=`，从管理器点 `[执行]` 打开，或读 `/data/adb/magpie/data/web.key` |
| 面板数据一动不动 | 属预期：读的是启停那一刻的快照 |
| 局域网连不上 | 改成 `0.0.0.0:<端口>` 后重启服务 |
| HTTPS 报证书错误 | 删掉 `/data/adb/magpie/data/certs/ca-bundle.crt*` 再重启，会自动重建 |
| 停止后又自己起来 | 属预期：看门狗会把意外退出的进程拉回。要彻底关掉自愈，停用整个模块 |

## 卸载

管理器里移除模块，或手动执行：

```sh
su -c sh /data/adb/modules/magpie/uninstall.sh
```

会依次：写卸载标记让看门狗退出、停服务、收掉守护进程和插件宿主 `magpie-bun`、清理旧版 dnsmasq、移除 PATH 里的 `magpie` 链接、删除整个 `/data/adb/magpie`（设置、供应商、网关 key、用量记录、证书、Bun 缓存都在里面），最后复查残留。

**注意：数据目录会被整个删除，不会保留。**

## 已知限制

- 面板的运行时长、内存、日志尾是**启停时的快照**，不随时间刷新。
- 不含 magpie 本体；本体更新由 magpie 自己负责，模块只管调度。
- 只在 arm64 + Android 14（HyperOS 2.0）实测；理论上 Android 10+ 的 arm64 设备都适用。
- 旧版 dnsmasq 清理只针对 `listen-address=::1` 的老进程，不碰系统热点的 dnsmasq。

更多细节见 [CHANGELOG.md](CHANGELOG.md)。

## 贡献者与致谢

- [DeepSeek](https://github.com/deepseek-ai) —— 本项目的脚本整理与文档撰写在 DeepSeek 模型辅助下完成。
- [magpie](https://github.com/yetone/magpie) —— 本模块服务的对象，MIT 许可，官网 [usemagpie.ai](https://usemagpie.ai)。

## 许可证

模块脚本以 [MIT](LICENSE) 发布。magpie 本体不在本仓库内，为[第三方软件](https://github.com/yetone/magpie)，版权归其作者所有。

刷模块前请确认设备有可用的救砖手段。
