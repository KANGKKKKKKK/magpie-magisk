<div align="center">

# Magpie AI 网关 · Android 模块

把 [magpie](https://github.com/yetone/magpie) 变成 Android 上的常驻服务：开机自己起来，被杀自己回来，一个按钮启停。

[![Release](https://img.shields.io/github/v/release/KANGKKKKKKK/magpie-magisk?style=flat-square&label=release)](https://github.com/KANGKKKKKKK/magpie-magisk/releases)
[![License](https://img.shields.io/github/license/KANGKKKKKKK/magpie-magisk?style=flat-square)](LICENSE)
[![Magisk](https://img.shields.io/badge/Magisk-20.4%2B-00af9c?style=flat-square)](https://github.com/topjohnwu/Magisk)
[![Platform](https://img.shields.io/badge/platform-arm64-blue?style=flat-square)](#环境要求)
[![Type](https://img.shields.io/badge/type-Magisk%20module-6ca0dc?style=flat-square)](#安装)

**简体中文** | [English](README_EN.md)

</div>

> [!NOTE]
> 本仓库只含模块脚本，**不含 magpie 本体**（arm64 二进制约 74 MB）。模块假定本体已装在 `/data/adb/magpie`，只负责让它稳定运行；provider、模型、额度这些 magpie 自身的配置不在本模块范围内。

## 目录

- [为什么需要它](#为什么需要它)
- [能做什么](#能做什么)
- [快速开始](#快速开始)
- [日常使用](#日常使用)
- [客户端怎么接入](#客户端怎么接入)
- [两把密钥的区别](#两把密钥的区别)
- [配置](#配置)
- [自检与排障](#自检与排障)
- [工作原理](#工作原理)
- [文件结构](#文件结构)
- [卸载](#卸载)
- [更新](#更新)
- [已知限制](#已知限制)
- [贡献者与致谢](#贡献者与致谢)
- [许可证](#许可证)

## 为什么需要它

[magpie](https://github.com/yetone/magpie) 是为桌面写的 Go 程序。搬到手机上能跑，但会连续撞上四件事：

- **DNS 查不到**。Go 找不到 `/etc/resolv.conf`，退回查 `::1:53`，日志里刷 `connection refused`。
- **HTTPS 全挂**。Go 只认 `/etc/ssl/certs/ca-certificates.crt` 这类固定路径，Android 上一个都没有——它的证书是 `/system/etc/security/cacerts/<hash>.0`，一证书一文件。
- **开机不自启**。Android 没有 systemd，重启之后得手动再起一次。
- **被杀就没了**。清理类 App、内存回收、系统「一键清理」都能直接 kill 掉它，而它自己不会回来。对下游客户端来说，这等于出口断了。

这个模块补上前三件，用看门狗解决第四件，并附一套能看见状态、能自己检查问题的周边。

## 能做什么

| 能力 | 说明 |
| --- | --- |
| 开机自启 | 等 `sys.boot_completed` 后拉起，不阻塞开机 |
| 进程守护 | 20 秒巡检，被杀或回收后自动拉回；用户主动停止时不强行恢复 |
| 一键启停 | 点 `[执行]`：在跑就打印接入信息并停止，没跑就启动并打开面板 |
| 状态可见 | 管理器那一行直接显示状态和可用地址（[示例](#执行按钮)），不用点按钮 |
| 自检 | `scripts/doctor.sh` 八项检查，直接告诉你哪里不对、下一步做什么 |
| 命令行 | `magpie` 自动进 PATH，补齐 `HOME`、`SSL_CERT_FILE`、`MAGPIE_BUN`、上游 DNS |
| CA 证书 | 合并系统根证书供静态 Go 使用，系统 CA 变化时自动重建 |
| 日志轮转 | 超过 5 MB 归档为 `.1`，只留一份 |
| 在线更新 | 管理器里可直接收到新版本 |
| 彻底卸载 | 停服务、收守护进程、清 PATH 链接、删数据目录，并复查残留 |

## 快速开始

### 前置条件

- [ ] 设备已 root，且装了 Magisk / KernelSU / APatch 之一
- [ ] 架构是 **arm64**（magpie 本体是 arm64 ELF，arm32 / x86_64 跑不了）
- [ ] magpie 本体已就位：`/data/adb/magpie/bin/magpie` 可执行，`/data/adb/magpie/data` 存在
- [ ] 会用管理器的「从本地安装」刷模块

> [!IMPORTANT]
> 模块**不带 magpie 本体**。只刷这个 zip，服务会因为找不到 `/data/adb/magpie/bin/magpie` 而启动失败——刷入时会提示，但不会中断安装。

### 步骤

**1. 确认本体在位**

```sh
su -c ls -l /data/adb/magpie/bin/magpie   # 应该是一个可执行文件
su -c chmod 755 /data/adb/magpie/bin/magpie
```

**2. 安装模块**

从 [Releases](https://github.com/KANGKKKKKKK/magpie-magisk/releases) 下载 `magpie-v0.7.zip`，管理器 → 模块 → 从本地安装 → 选 zip。

**3. 重启**

模块会等 `sys.boot_completed` 再拉起服务，不需要解锁屏幕。

**4. 验证**

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service status
# running (PID <pid>)

su -c sh /data/adb/modules/magpie/scripts/doctor.sh   # 八项自检，出问题会告诉你怎么修
```

管理器里那行描述应该也从「点 [执行] 启动或停止」变成「magpie 运行中 (v…) | 点 [执行] 停止」。

**5. 打开面板**

服务已经在跑，**这时不要点 `[执行]`**——它此刻是停止按钮。直接打开面板地址：

```sh
su -c cat /data/adb/magpie/run/web.url
# http://127.0.0.1:3430/?k=<32 位访问密码>
```

把打印出来的地址粘进手机浏览器即可。

> [!TIP]
> 想从电脑上打开面板，先把 [配置](#配置) 里的 `MAGPIE_WEB_ADDR` 改成 `0.0.0.0:3430` 并重启服务，再用面板/自检里给出的局域网地址访问。**开之前先看一眼下面的[两把密钥](#两把密钥的区别)那一节。**

不想刷 zip 的，手动放置：

```sh
unzip magpie-v0.7.zip -d /data/adb/modules/magpie
chmod 755 /data/adb/modules/magpie/*.sh /data/adb/modules/magpie/scripts/*.sh
chmod 600 /data/adb/modules/magpie/scripts/magpie.config
```

## 日常使用

### 执行按钮

管理器模块页的 `[执行]` 是**开关**，行为取决于当前状态：

| 当前状态 | 点一下会怎样 |
| --- | --- |
| 服务在跑 | 先打印 PID、网关地址、面板地址，然后**停止**（写 `.user_stopped`，看门狗不会马上拉起） |
| 服务没跑 | 启动，打印同样的信息，并打开面板 |

同一颗按钮，两种结果。用之前先看模块描述那行写的是什么。

那行文字会自动更新，不需要点任何按钮就能看到该填进客户端什么：

```
🟢 运行中 v0.1.4260 | 192.168.1.5:3425      ← 运行中，并给出可用的局域网地址
🟢 运行中 v0.1.4260 | 仅本机                 ← 只监听 127.0.0.1，别的设备连不上
🔴 已停止 | 点 [执行] 启动
```

地址变了（WiFi 重连、热点开关、切飞行模式）会自动刷新，不会让你照着旧地址折腾。字体不支持 emoji、显示成方框时，把配置里的 `MAGPIE_ICON` 设成 `0`，就会换成 `[运行中]` / `[已停止]` 纯文本。

> [!NOTE]
> `[执行]` 按钮由管理器提供。较老的 Magisk 版本没有这个按钮，用下面的命令行启停即可。

### 两个「面板」，别弄混

模块里有两个完全不同的页面，地址和用途都不一样：

| | magpie 自带的面板 | 模块自带的 webroot 面板 |
| --- | --- | --- |
| 地址 | `http://<host>:3430/?k=<data/web.key>` | 由宿主提供，见右栏 |
| 谁提供 | magpie 自己（`serve --web=…`） | `webroot/index.html`，需要 **KernelSU 的 WebUI** 或 Magisk 的 **WebUI-X** 模块来托管 |
| 能看到什么 | magpie 的完整应用界面（Agents / Sessions / Library / Settings） | 服务状态与 PID、网关地址与 API Key、面板地址与访问密码、日志尾 |
| 纯 Magisk 下 | ✅ 可用，地址由 `run/web.url` 给出 | ❌ 没有宿主就打不开；此时 `webroot/status.json` 仍然会写，脚本可以直接读 |

![模块自带的 webroot 面板](docs/panel.png)

（截图是**模块自带的 webroot 面板**，需要在 KernelSU WebUI / WebUI-X 里打开。API Key 与访问密码默认折叠为「点击「显示」查看」，未被截入截图。）

### 命令行

```sh
su -c magpie --version
# 示例输出：magpie 0.1.3620   ← 版本随本体更新而变，别把这里当固定值
```

`magpie` 由 `scripts/magpie-cli.sh` 包装，自动处理 Android 上缺的环境变量，用法与官方 CLI 一致。

### 服务控制

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service start
su -c sh /data/adb/modules/magpie/scripts/magpie.service stop
su -c sh /data/adb/modules/magpie/scripts/magpie.service restart
su -c sh /data/adb/modules/magpie/scripts/magpie.service status
su -c sh /data/adb/modules/magpie/scripts/doctor.sh          # 八项自检
```

`start` 失败返回非 0，日志在 `/data/adb/magpie/run/magpie.log`。

## 客户端怎么接入

### 接入前检查

- [ ] 服务在跑：`su -c sh /data/adb/modules/magpie/scripts/magpie.service status`
- [ ] magpie 里**至少配好一个 provider 并且是启用状态**（只建网关 key 不会凭空变出模型）
- [ ] 有一把**已启用**的网关 key
- [ ] 同一台手机上用 `127.0.0.1`；别的设备要连，先开放局域网并确认两边同一网段

```sh
# 一条命令看全：本体、进程、端口、密钥、暴露面
su -c sh /data/adb/modules/magpie/scripts/doctor.sh
```

### 第一步：拿到地址和密钥

```sh
su -c magpie gateway-key add phone
# sk-magpie-key-…      ← 只打印这一次，当场存好
```

面板首页也会显示同样的两项（这对接口地址与 API Key）。要填的是：

| 要填的 | 值 |
| --- | --- |
| 接口地址（Base URL） | `http://127.0.0.1:3425/v1` |
| API Key | 上面打印出来的密钥 |

> [!WARNING]
> `gateway-key list` **不会**显示完整密钥，只给 ID 和掩码。密钥只在 `add` / `rotate` 时打印一次，丢了就用 `magpie gateway-key rotate <id>` 换一把。

### 第二步：填进客户端

支持自定义 OpenAI 接口的客户端都能接，通常只有三个字段。以常见的 OpenAI 兼容客户端为例：

```jsonc
{
  "base_url": "http://127.0.0.1:3425/v1",   // 必填；末尾的 /v1 不能省
  "api_key":  "sk-magpie-key-…",            // 必填；第一步拿到的那把
  "model":    "<provider>/<model>"          // 必填；模型名要带供应商前缀
}
```

- 模型名写 `<provider>/<model>`，可用哪些看 `magpie providers`，或直接问网关：`GET /v1/models`。
- 别的设备上把 `127.0.0.1` 换成手机的局域网地址（自检里会给出），例如 `http://192.168.1.100:3425/v1`。

<details>
<summary>其它协议的 base URL（Anthropic / Gemini）</summary>

```text
OpenAI     http://127.0.0.1:3425/v1        # /v1/chat/completions、/v1/responses
Anthropic  http://127.0.0.1:3425           # /v1/messages
Gemini     http://127.0.0.1:3425           # /v1beta/models/{model}:generateContent
```

magpie 会自动翻译多协议请求，细节见 [magpie 的接入文档](https://github.com/yetone/magpie/blob/main/docs/integrating.md)。

</details>

### 第三步：验证连接

**在手机上**（没有 `curl`，用 busybox 的 `wget`）：

```sh
wget -q -O - http://127.0.0.1:3425/ | head -c 200
```

**在电脑上**（需要先开放局域网）：

```sh
curl -s http://192.168.1.100:3425/ | head -c 200
curl -s -H "Authorization: Bearer sk-magpie-key-…" http://192.168.1.100:3425/v1/models | head -c 200
```

连上时长这样（字段值随版本和你配的 provider 变化）：

```jsonc
// GET /
{"apis":["/v1/chat/completions","/v1/responses","/v1/messages", …],
 "models":20,"name":"magpie","pid":28622,"serves":"serve","version":"0.1.4260"}

// GET /v1/models
{"data":[{"id":"<provider>/<model>","object":"model","owned_by":"<provider>", …}],"object":"list"}
```

看到 `"name":"magpie"` 就说明网关是通的。再发一条真正的请求：

```sh
curl http://127.0.0.1:3425/v1/chat/completions \
  -H "Authorization: Bearer sk-magpie-key-…" \
  -H "Content-Type: application/json" \
  -d '{"model":"<provider>/<model>","messages":[{"role":"user","content":"hi"}]}'
```

<details>
<summary>连接失败排查（FAQ）</summary>

| 现象 | 多半是 |
| --- | --- |
| `Connection refused` / 连接被拒绝 | 服务没跑，或端口不对。`magpie.service status` 看一眼；自检里「端口监听」那项会直接告诉你 |
| 电脑上连不上，手机上正常 | 还在只监听 `127.0.0.1`。把 `MAGPIE_ADDR` 改成 `0.0.0.0:3425` 重启服务，再用 `ss -ltnp` 确认 3425 真的在监听 |
| 超时，不报拒绝 | 两边不在同一网段，或路由器开了 AP 隔离；也可能是自检里那个「局域网地址」其实是运营商级 NAT（100.64–100.127.x），那种地址外部设备根本到不了 |
| 404 | Base URL 少了 `/v1` |
| 401 | 从别的设备访问时，key 必须是一把**已启用**的网关 key；本机回环访问不校验，所以「本机能用、电脑 401」是正常的 |
| `model not found` | 该模型没在 magpie 里启用，或那把 key 的 models 限制不含它 |
| 面板打开是 401 | 链接少了 `?k=`。用 `run/web.url` 里的完整地址，或点 `[执行]` 启动时自动打开 |
| 面板能开，但里面的 API Key 显示「点击「显示」查看」 | 这是刻意的，点一下即可 |

一条命令查完这些：`su -c sh /data/adb/modules/magpie/scripts/doctor.sh`

</details>

## 两把密钥的区别

|  | 网关 API Key | 面板访问密码 |
| --- | --- | --- |
| 长什么样 | 默认生成的形如 `sk-magpie-key-…`；用 `--key` 自填的格式随意 | 32 位十六进制 |
| 存哪 | `data/.config/magpie/caller-keys.json`（只存掩码，明文仅创建时打印一次） | `/data/adb/magpie/data/web.key` |
| 谁用 | 客户端调 `/v1` | 浏览器开面板（URL 里的 `?k=`） |
| 怎么来 | `magpie gateway-key add <名>`，或 `add <名> --key <值>` 用自己的 | 首次启动自动生成，重启不变 |
| 作用 | 决定**谁能调用**、能用哪些模型与账号、多少额度 | 决定**谁能看见面板** |

`?k=` 的流程是：带上正确密码的第一个请求返回 303 并写入登录 cookie，之后浏览器凭 cookie 访问。所以地址里的 `?k=` 只需要第一次带上。

> [!IMPORTANT]
> **本机回环访问不校验密钥。** magpie 文档的原话是「On this machine the gateway takes any key」，实测不带 `Authorization` 头也能调通 `/v1/models`。所以「有没有 key」不是本机的安全边界，别拿它当。

面板会明文显示网关 API Key，因此访问密码泄露的后果不只是「看到运行状态」，而是「**可能拿到那把 API Key，并按它的权限调用模型**」——能调哪些模型、账号、额度仍由那把 key 的配置决定。

开放局域网后的暴露面：

- `MAGPIE_ADDR=0.0.0.0:3425` → 网关对同网段可见。**从别的设备访问必须带一把已启用的网关 key**，随便填字符串会被拒；但网关本身可被探测。
- `MAGPIE_WEB_ADDR=0.0.0.0:3430` → 面板暴露，不知道 `?k=` 会 401；密码一旦泄露，对方能打开面板并读到上面显示的 API Key。

顺序建议：**先建好网关 key，再开局域网**；只在本机用就保持默认的 `127.0.0.1`。不确定的时候跑一次自检，它会把当前暴露面直接列出来。

## 配置

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `magpie_path` | `/data/adb/magpie` | 数据目录，二进制 / 日志 / magpie 自身数据都在里面 |
| `MAGPIE_ADDR` | `127.0.0.1:3425` | API 网关监听地址 |
| `MAGPIE_WEB_ADDR` | `127.0.0.1:3430` | WebUI 监听地址；留空则用 `MAGPIE_ADDR` 的 host + 3430 |
| `MAGPIE_DNS` | `223.5.5.5 119.29.29.29 8.8.8.8` | 上游 DNS，空格分隔 |
| `MAGPIE_ICON` | `1` | 管理器状态图标：`1` 用 🟢/🔴，`0` 用 `[运行中]`/`[已停止]` |

脚本按顺序找配置文件：先 `/data/adb/magpie/scripts/magpie.config`，不存在才用模块里的 `scripts/magpie.config`。所以**改配置请改数据目录那份**，它不会被模块更新覆盖；两者都不在时使用内置默认值，且默认全部监听 `127.0.0.1`。

改完重启服务生效：

```sh
su -c sh /data/adb/modules/magpie/scripts/magpie.service restart
```

## 自检与排障

`scripts/doctor.sh` 一次跑八项检查（只读，不改任何配置）：

```
[1/8] 本体与进程      本体可执行？版本？PID？
[2/8] 端口监听        网关 / 面板端口有没有人听
[3/8] 本机可用性      网关是否返回 200
[4/8] 面板与访问密码  data/web.key 在不在？带密码能不能进
[5/8] 网关密钥        有几把已启用的 key
[6/8] CA 证书包       证书张数与权限
[7/8] 局域网暴露      是否已对局域网开放、对外广播的地址是什么
[8/8] 日志与磁盘      日志大小、数据目录可写、剩余空间
```

| 现象 | 处理 |
| --- | --- |
| 启动失败，日志说端口占用 | 上次进程没退干净，`pidof magpie` 确认后 kill，再 `start` |
| 面板数据一动不动 | 属预期：webroot 面板读的是 `status.json`，即启停那一刻的快照 |
| HTTPS 报证书错误 | 删掉 `/data/adb/magpie/data/certs/ca-bundle.crt*` 再重启，会自动重建 |
| 停止后又自己起来 | 属预期：看门狗会把意外退出的进程拉回。要彻底关掉自愈，停用整个模块 |
| 改了 `magpie.config` 没生效 | 确认改的是 `/data/adb/magpie/scripts/magpie.config`，然后 `restart` |
| 开机没自启 | 看 `run/watchdog.log`；手动停过服务会留 `.user_stopped` 标记，`start` 会清掉它 |

更多细节见 [CHANGELOG.md](CHANGELOG.md)。

## 工作原理

```mermaid
flowchart TD
  subgraph phone["手机"]
    MGR["Magisk / KernelSU 管理器"] -->|"service.sh 开机拉起"| SVC["magpie serve<br/>网关 :3425 · 面板 :3430"]
    WD["看门狗<br/>每 20 秒巡检"] -.->|"进程没了就拉回"| SVC
    SVC -->|"status.sh"| SJ["webroot/status.json"]
    SJ -.->|"KernelSU WebUI 读"| WP["模块 webroot 面板"]
  end
  APP["同机客户端"] -->|"127.0.0.1:3425/v1"| SVC
  LAN["局域网设备"] -->|"须带已启用的网关 key"| SVC
  BR["浏览器"] -->|"?k=web.key"| SVC
  SVC --> UP["上游 provider<br/>DeepSeek / ChatGPT / …"]
```

<details>
<summary>三个入口脚本各做什么（点开展开）</summary>

- **`service.sh`**：开机后等 `sys.boot_completed=1`，归档日志、启动服务、刷新状态；另外常驻一个 20 秒巡检的看门狗，发现进程没了就重新拉起。模块被禁用、正在卸载或目录被删时，看门狗自行退出。
- **`action.sh`**：读 PID 判断状态。运行中就先打印接入信息再停止；未运行就启动、打印信息并打开面板。两条路径都刷新模块描述。
- **`scripts/magpie.service`**：真正的服务控制。启动前清理 v0.2 遗留的 dnsmasq、注入环境变量、拉起 `magpie serve --web=<addr>`、写 PID 与面板链接。

</details>

<details>
<summary>三个设计取舍：DNS、CA 证书、局域网地址（点开展开）</summary>

- **DNS 不占 53 端口**。用 Go 官方的 `DNS_LOCAL_HOSTNAMES` 直连公网 DNS，不启动本地 dnsmasq，因此不会和系统热点的 dnsmasq 抢端口——这是 v0.2 踩过的坑。
- **CA 证书自己更新**。给系统证书目录算指纹（文件数 + 目录 mtime，`/system/etc/security/cacerts` 与 APEX 那份一起算），存在 `ca-bundle.crt.stamp`；启动服务和调用 `magpie` 命令时比对，不一致就重建。先写临时文件、校验有证书才原子替换，失败保留旧包继续用。

  信任范围就是系统本来那些根证书：没有额外安装任何证书，没有中间人，也没有关掉校验。
- **局域网地址会挑**。优先 WiFi / 热点 / USB 网卡，跳过移动数据接口；并排除回环、链路本地、mihomo 的 fake-ip（198.18.0.0/15）和运营商级 NAT（100.64.0.0/10）——后两者报出去谁也连不上。

</details>

## 文件结构

```
magpie-magisk/
├── module.prop                       模块信息（名字、版本、描述、updateJson）
├── customize.sh                      刷入时执行：设权限、查本体
├── service.sh                        开机自启 + 看门狗
├── action.sh                         管理器 [执行] 按钮
├── uninstall.sh                      卸载清理
├── update.json                       在线更新用的清单
├── build.sh                          打包成可刷入的 zip
├── scripts/
│   ├── magpie.service                start / stop / restart / status
│   ├── status.sh                     生成状态描述、status.json、日志尾
│   ├── doctor.sh                     八项自检
│   ├── magpie-cli.sh                 补环境变量后调用 magpie 本体
│   └── magpie.config                 配置（默认值）
├── webroot/
│   └── index.html                    模块自带的面板（需 KernelSU WebUI / WebUI-X）
├── docs/
│   └── panel.png                     README 里的面板截图
└── META-INF/com/google/android/      Magisk 刷机脚本
```

运行时生成、不进仓库：

```
/data/adb/magpie/run/magpie.log        服务日志
/data/adb/magpie/run/watchdog.log      看门狗日志
/data/adb/magpie/run/web.url           带密码的面板地址
/data/adb/magpie/run/lan.url           局域网地址（开放局域网时）
/data/adb/magpie/run/.user_stopped     用户主动停止的标记
/data/adb/magpie/run/magpie.pid        PID 文件
/data/adb/magpie/data/certs/           CA 证书包与指纹
webroot/status.json                    面板数据（含密钥，权限 600）
webroot/lastlog.txt                    面板日志尾（权限 600）
```

## 卸载

管理器里移除模块，或手动执行：

```sh
su -c sh /data/adb/modules/magpie/uninstall.sh
```

会依次：写卸载标记让看门狗退出、停服务、收掉守护进程和插件宿主 `magpie-bun`、清理旧版 dnsmasq、移除 PATH 里的 `magpie` 链接、删除整个 `/data/adb/magpie`（设置、供应商、网关 key、用量记录、证书、Bun 缓存都在里面），最后复查残留。

> [!WARNING]
> 数据目录会被整个删除，不会保留。想留一份就先自己备份 `/data/adb/magpie/data`。

## 更新

模块内置在线更新：`module.prop` 里的 `updateJson` 指向本仓库的 [`update.json`](update.json)。

- 管理器会根据 `versionCode` 判断有没有新版本，需要时提示并一键更新。
- 发新版时改三处：`module.prop` 的 `version` / `versionCode`，以及 `update.json` 的 `version` / `versionCode` / `zipUrl`。
- 更新模块**不会**动 `/data/adb/magpie`，所以你配的 provider、密钥、日志都保留。

## 已知限制

- webroot 面板的运行时长、内存、日志尾是**启停时的快照**，不随时间刷新。
- 不含 magpie 本体；本体更新由 magpie 自己负责，模块只管调度。
- KernelSU / APatch 的路径都已经在脚本里覆盖（`ksud`、`/data/adb/ap/bin`、`/data/adb/ksud`），但**只在 Magisk 31.1 上实测过**，KernelSU / APatch 未实测。
- 只在 arm64 + Android 14（HyperOS 2.0）实测；理论上 Android 10+ 的 arm64 设备都适用。
- 旧版 dnsmasq 清理只针对 `listen-address=::1` 的老进程，不碰系统热点的 dnsmasq。

## 贡献者与致谢

- [DeepSeek](https://github.com/deepseek-ai) —— 本项目的脚本整理与文档撰写在 DeepSeek 模型辅助下完成。
- [magpie](https://github.com/yetone/magpie) —— 本模块服务的对象，MIT 许可，官网 [usemagpie.ai](https://usemagpie.ai)。

## 许可证

模块脚本以 [MIT](LICENSE) 发布。magpie 本体不在本仓库内，为[第三方软件](https://github.com/yetone/magpie)，版权归其作者所有。

刷模块前请确认设备有可用的救砖手段。
