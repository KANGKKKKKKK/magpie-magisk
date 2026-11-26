# 变更记录

## 未发布

### 生命周期、卸载与安装安全

- start/stop/restart/toggle 使用同一互斥锁，停止意图在等待锁时立即落盘；卸载清理 dnsmasq keeper 与 magpie 前复核进程身份。
- 修复过期安装锁回收竞态；回退改为同目录临时文件加 mv 原子替换，并扩大子路径符号链接检查。
- web.key 使用 umask 077、0600 与原子写入，启动日志不再输出 `?k=` 凭据。
- 磁贴 Shell 并发消费 stdout/stderr，增加超时、单流 64 KiB 上限与进程清理。
- CI/release 显式检查无后缀核心脚本；Release 上传 SHA256SUMS 与构建 provenance，update.json 格式不变。
- 测试：383 条断言（57 + 13 + 43 + 33 + 237），另有 47 条 JVM 用例。


## v1.2.4 — 2026-11-25

本次的重点是磁贴：模块自检和 App 里的自查共用同一套判断，
装完不用登 ADB 也能知道「显示和实际不一致」到底是谁的问题。

模块里带的是磁贴 App **1.2.5**（1.2.4 的冻结相关修复也一并包含）。

### 磁贴 App 1.2.5：加「检查磁贴状态」

- App 主界面新增「自查」区块，点一下把当前情况逐条列出来：服务在不在跑、root 授权状态、磁贴画的是什么、和实际是否一致、进程有没有被冻结。
- 判断逻辑放在模块的 `scripts/tile-check.sh`，`doctor.sh [9/10]` 用的是同一个脚本。两边取数与判定一致，不会出现「医生说不没事、App 说被冻了」。
- **没有加「加入电池优化白名单」**。磁贴是纯 TileService，不做后台任务、不联网、不设定时器；它的绑定由 SystemUI 在前台发起，不受 `RUN_ANY_IN_BACKGROUND` 限制（实测该值仍是 `ignore` 也能 188ms 拉起并正常刷新）。真问题是被冻结模块冻住，那个按钮会把人引偏。
- 冻结检测不假设任何特定模块：只读 `cgroup.freeze` 并核对 `/proc/<pid>/cgroup` 归属，命中后按场上证据给出疑似来源（NoActive / CZero / 系统 `cached_apps_freezer` / 厂商 greezer）。
- 「显示和实际不一致」只提示、不当故障：磁贴只在展开面板和点击时重读状态，从命令行或看门狗启停服务后显示旧值是预期行为。

### 自检增加磁贴一项

- `doctor.sh` 从九项变十项，新增 `[9/10] 磁贴（可选组件）`，原「日志与磁盘」顺延为 `[10/10]`。
- 未安装、未加入控制中心都算通过（可选组件）；只有「root 被拒绝」和「磁贴显示模块未安装」算失败。

### 测试

- 新增 `tests/jvm/SelfCheckTest.java`：28 条用例覆盖自查结论的各种分支（无 root、模块缺失、旧版模块、服务停启、root 被拒/未授权、非 Magisk 环境、不在面板、未绘制、处理中、冻结来源已知/未知）。
- CI 的「磁贴的状态判定逻辑」步骤现在跑两套 JVM 用例（13 + 28）。

### 安装与卸载路径安全

- 安装器与卸载器共用默认拒绝白名单：仅允许 `/data/adb/magpie`、`/data/adb/modules/magpie` 及各自子目录；`status`、`check`、`plan`、`install`、`rollback` 入口先校验；安装器还会拒绝目标路径和相关子路径中的符号链接。
- 旧版自定义数据目录不会自动迁移或删除。若目录不在允许范围内，安装器会拒绝对它执行上述入口；服务不会自动搬动或清除该目录。
- 该状态下直接运行模块里的 `magpie.service` 仍按原配置工作；`[执行]` 菜单与 `action.sh start|stop|restart` 会先做就绪检查，因此会被路径校验拦下。

### 磁贴桌面入口对账

- `pm dump` 仅按目标包、User 0 的 `disabledComponents` 小节及完整组件类名判定；不会把其他包、用户或相邻小节中的同名内容当作已隐藏。
- `pm dump` 失败、输出为空或无法确认时，幂等补做 `pm disable --user 0`，不误报已隐藏。
- **更正 v1.2.3 的旧描述**：旧文把 `disabledComponents` 段描述成“以空行结束”不准确。空集合时 AOSP 不打印该标题；非空列表的段尾也不保证有空行。此处是对历史表述的纠正，不是本版新发现的行为；当前对账按包／用户／缩进小节上下文和完整类名识别，不要求段尾必须有空行。

### 验证

- 五套脚本测试：372 条断言（53 + 13 + 43 + 26 + 237）；另有 41 条 JVM 用例（`ClassifyTest` 13、`SelfCheckTest` 28）。测试结果以实际运行记录为准。

## 磁贴 App 1.2.4 — 2026-11-25

控制中心磁贴显示的状态和实际运行状态偶尔不一致。查下来不是「读错了」，
而是**它根本没被叫醒**：MIUI / HyperOS 上的冻结类模块（本机是 NoActive）
会在磁贴进程空闲几十秒后把整个进程冻住（`cgroup.freeze=1`）。冻结期间
SystemUI 展开控制中心时发的 `onStartListening` 到不了 App，`su` 一次都不执行，
磁贴就停在最后一次画出的画面上。

实测：冻结状态下 `cmd statusbar expand-settings`，SystemUI 侧有
`set listening to true`，App 侧一行日志都没有；手动 `echo 0 > .../cgroup.freeze`
解冻后立刻恢复。所以根治只能靠白名单（本机已把磁贴 UID 加进 NoActive
`whiteUidSet`，重启生效）。

App 侧同时修掉三处「会把已知状态丢掉」的地方，使症状不至于被放大：

| 位置 | 问题 | 做什么 |
| --- | --- | --- |
| `render()` | `getQsTile()` 返回 null 时直接 return —— 那次刷新永久丢失 | 按 60/150/400/900 ms 重试，带序号防止慢的旧结果盖掉新状态 |
| `classify()` | 输出认不出来时兜底成「已停止」，把「不知道」画成「服务挂了」 | 拆出 `resolve()`：认不出来沿用上次已知状态；`classify()` 独立返回 `unknown` |
| `onStartListening()` | 缓存过期时无条件先画灰的「处理中」，su 慢一点就整块变灰 | 有已知状态先用它顶上，完全没头绪才画「处理中」 |

`MainActivity` 同步改用 `resolve()` 的判定语义，`unknown` 时不写成「已停止」。


## v1.2.3 — 2026-11-24

第三轮复审的修复：一个能删到系统命脉的白名单、一个永远不匹配的判据，
以及「在系统设置里隐藏」那一半没接上。

### 修法

| 位置 | 问题 | 做什么 |
| --- | --- | --- |
| `lib.sh` `magpie_path_cleanable()` | 白名单是**枚举危险路径**：`/data/adb/magisk`、`/data/adb/magisk.db`、`/data/adb/service.d`、`/data/misc/wifi`、`/data/user/0/*` 都不在清单里，配置写错一个词就 `rm -rf` | 改成**默认拒绝**，只放行 `/data/adb/magpie` 与 `/data/adb/modules/magpie` |
| `tile-app.sh` `tile_reconcile_launcher()` | 旧记录把 `pm dump` 的 `disabledComponents` 边界写成以**空行**结束（该边界描述不准确，见本文件「未发布」更正）；段内写的是 `com.ruin.magpie.tile.Launcher`，不是 `包名/.Launcher` —— grep 永远不匹配，每次开机白跑一次 `pm disable` | 当时改为匹配完整类名；当前对账按包、User 0 与缩进小节上下文识别，不要求空行作为段尾 |
| `LauncherIcon.reconcile()` | `!want && systemHidden` 这一支（用户在系统设置里停用）只改 prefs、没写标记文件，系统重置后开机找不到标记就不补隐藏 | 补 `writeFlag(true)` |
| `LauncherIcon.writeFlag()` | 写入失败被静默吞掉 | 失败时 `Log.w` 留痕 |
| `Shell.java` | 两段重复 javadoc | 合并成一段 |

### 行为变化

自定义 `magpie_path` 到本模块两个位置之外的用户，**卸载时不再自动删除该目录**，
会打印「跳过可疑路径，请手动确认」。这是有意的取舍：白名单漏一条的代价是
`rm -rf` 掉 `magisk.db` 或 `/data/misc/wifi`（WiFi 密码），不值得为省一次手动删除去冒险。

### 验证

- 真机核对 `pm dump` 真实格式并确认组件名是完整类名。旧记录称段落以空行结束，此边界描述现已更正：空集合时不打印标题，非空列表段尾也不保证有空行（见「未发布」说明）。
- 真机确认 `/data/adb/magpie/run` 实际是 `0777`；文档此前写「run 是 0700」是错的，
  真正的屏障是父目录 `/data/adb` 的 `0700` —— 两处文档已更正
- `test-lib.sh` 新增 15 条：`magisk` / `ksu` / `ap` / `magisk.db` / `service.d` /
  `misc/wifi` / `user/0` 一律拒绝，本模块路径仍放行；`pm dump` 的 stub 改成真实格式
- 合计 317 条（46 + 13 + 40 + 26 + 192），另有 13 条 JVM 用例

### 已知降级

自定义安装位置不再自动清理（见「行为变化」）。

## v1.2.2 — 2026-11-24

修「隐藏过的桌面图标会自己冒出来」。

### 问题

`activity-alias` 的启用状态是**系统侧**的，会在覆盖安装、清除数据、
部分系统更新、以及模块更新时被重置回 `default`。一旦重置，隐藏过的图标
就自己回来了 —— 而 App 里记的还是「已隐藏」，两边对不上。

用户隐藏图标后**不会再打开 App**，所以只在 `onCreate` 里对账不够，
开机时也得补一次。

### 修法

| 位置 | 做什么 |
| --- | --- |
| App `LauncherIcon.reconcile()` | 打开 App 时对账：记录说隐藏但系统被重置 → 重新隐藏 |
| `service.sh` 开机路径 | `tile_reconcile_launcher` 读标记文件，已隐藏但系统重置 → 重新禁用 |

**意图记在 `/data/adb/magpie/run/.tile_launcher_hidden`，不是 App 的
SharedPreferences**：App 数据在 CE 存储，模块脚本跑在 Magisk 的 mount
namespace 里看不到那条路径（实测只有 `/proc/<app pid>/root` 下能读到，
而开机时 App 还没启动）。放模块自己的 run 目录，两边都能访问。

### 验证（真机端到端）

1. 点「隐藏桌面图标」→ 入口 `No activity found`，标记文件已写入
2. 模拟系统重置（`pm enable`）→ 图标自己冒出来
3. 跑开机对账 → 输出「已按用户设置重新隐藏桌面图标」，入口回到 `No activity found`

`test-lib.sh` 新增 3 条：没有标记时不动作、有标记且未禁用则隐藏、已禁用时幂等。
合计 302 条（46 + 13 + 40 + 26 + 177），另有 13 条 JVM 用例。

### 已知降级

手动删掉 `/data/adb/magpie/run/` 目录会连带丢掉标记，那种情况下图标会保持
系统状态、不再自动隐藏。下次打开 App 会重新对账并补写标记。

磁贴 App versionCode 6 / versionName 1.2.2。

## v1.2 — 2026-11-24

磁贴 App 加一个开关：可以隐藏桌面图标，只留控制中心磁贴。

这一版还修了一批代码审查发现的问题，其中一个是**数据毁灭级**的。

### 复审补充：`..` 也能绕过（同一条防线的另一半）

上一轮修的是末尾斜杠，但 `case` 匹配发生在**原始字符串**上，而 `rm -rf`
执行时会做一次 POSIX 路径解析。`magpie_path="/data/../data"` 归一化后仍是
`/data/../data`，白名单匹配不上 → 放行 → 实际删的是 `/data`。

修复：`magpie_norm_path` 遇到含 `.` / `..` 的路径先用 `readlink -m` 解析成真实路径
再判定（拿不到时退回 `cd + pwd -P`，再不行就返回失败、由调用方拒绝删除）。

顺带修了同一处的三个问题：

- **`install.sh` 从来没 source 过 `lib.sh`**。上一轮加的归一化分支里写的是
  `if command -v magpie_norm_path`，而那个函数根本不存在，于是整段被静默跳过 ——
  安装器又回到原来的 `case`。现在补上 source；**并且 lib.sh 缺失时直接拒绝**
  而不是「跳过检查就当通过」。
- **`test-install.sh` 新增 7 条**：用 `install --yes` 的真实入口跑可疑路径
  （`/data/`、`/data`、`/`、`/data/../data`、`/data//adb` 等），断言明确拒绝。
  上一轮只测了 lib.sh 里的函数本身，测不出「接线断了」。
- `check_target` 的报错文案从「末尾有多余斜杠」改成「不是规范路径」并给出解析结果 ——
  它现在挡的是所有归一化差异，不只是斜杠。

### 磁贴的「模块未安装」终于显示得出来

`classify()` 里有 `nomodule` 分支、`strings.xml` 里有文案，但没有任何代码路径会返回它。
模块被删后 `sh` 的 stdout 为空、stderr 是 `cannot open`，于是落到 `noroot` ——
用户看到「需要 root」，去 root 管理器里翻授权，而真正原因一个字都没提。

修复：`Shell.moduleExists()`（`/data/adb/modules` 是 0755，App 能 stat，不需要 root），
磁贴与界面都先查它再决定要不要跑 su。同时 `MainActivity` 改用与磁贴同一个
`classify()`，两边不再给出不同结论。

### 其他

| 项 | 说明 |
| --- | --- |
| `build.sh` 类清单 | 补上 `LauncherIcon`（决定「隐藏图标」的类），与 `ci.yml` 一致。漏了它时编译能过、dex 也在，运行时才 `NoClassDefFoundError`。 |
| `LauncherIcon` 注释 | 写着「TileService 支持 onLongClick」，与仓库里另外三处说明矛盾。改成 `ACTION_QS_TILE_PREFERENCES`。 |
| `uninstall.sh` 卸磁贴 | 改成直接 `pm uninstall com.ruin.magpie.tile`，不依赖 `scripts/tile-app.sh` —— 从管理器移除模块时那个脚本已经没了。 |
| alias 冗余属性 | 去掉 `icon` / `label`（继承 `targetActivity`），避免「改一个忘另一个」。 |
| JVM 输出编码 | `java` 加 `-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8`，否则中文用例在 GBK 环境下打成问号。 |

### 严重：卸载的路径白名单能被一个斜杠绕过

`uninstall.sh` 的 `cleanable()` 用 `case` 整串匹配，而 `/data/` 匹配不上 `/data`
（少了 `/data/*` 这一支），于是落到「是绝对路径就放行」那一支，返回可删，
随后 `rm -rf` 作用在 `/data` 上。**触发只需要配置里写 `magpie_path="/data/"`**，
多一个斜杠。

实测（修复前）：`/data/`、`/data//`、`/data/adb/`、`/data/adb/modules/` 全部放行。

修复：把归一化与白名单收进 `lib.sh`（`magpie_norm_path` / `magpie_path_cleanable`），
先剥掉所有末尾斜杠、折叠重复斜杠再比；`uninstall.sh` 与 `install.sh` 共用同一份。
`lib.sh` 缺失时 `cleanable` 一律返回「不可删」—— 宁可留垃圾，也不能 rm 一个没校验过的路径。
`test-lib.sh` 新增 25 条用例，其中 2 条**直接从 `uninstall.sh` 原文抽 `cleanable` 来跑**，
脚本与测试不会各改各的。

### CI 的「磁贴 App 能编译」一直红

`aapt package -J` **不会自己创建目标目录**，`mktemp -d` 里没有 `gen/`，
于是报 `Unable to open class file .../gen/.../R.java` —— 而它的退出码还是 0，
光看 `$?` 发现不了。`tile-app/build.sh` 因为提前 `mkdir -p` 所以没暴露。

顺带：`javac` 没给 `-encoding UTF-8`，源码注释是中文，平台编码不是 UTF-8 时
会一片 `unmappable character`；`javac ... | grep ...` 会让 `$?` 变成 grep 的退出码，
编译失败被当成成功。

修复：`mkdir -p` + `-encoding UTF-8` + 先落文件查退出码再过滤 + 逐个检查
`MagpieTileService` / `MainActivity` / `LauncherIcon` / `Shell` 的 `.class` 是否都在。

### 磁贴把「启动失败」画成别的状态

`toggle` 失败时输出 `failed`、退出码非 0，而磁贴的判定是 `!r.ok → noroot`，
于是「启动失败」被显示成「需要 root」。同时 `status` 输出的是
`running (PID 123)`，原来的 `endsWith("running")` 根本匹配不上。

修复：抽 `classify()` 按**输出**判定（不看退出码 —— su 成功后退出码来自脚本本身，
`sh: 脚本不存在` 的 127 也会非 0），取最后一行做双向匹配，新增「启动失败」文案。
配 `tests/jvm/ClassifyTest.java` 10 条用例，CI 里跑。

### 用户配置那份文件从来没被创建

README 与 FAQ 都让用户改 `/data/adb/magpie/scripts/magpie.config`，
但全仓库没有任何地方创建它 —— 照文档做的用户第一步就撞上「文件不存在」。

修复：`service.sh` 开机路径补 `seed_user_config`（不存在才复制、先写临时文件再 `mv`、
权限 600，已存在绝不动）。实测：用户改过之后再跑不会被覆盖。

### 其他

| 项 | 说明 |
| --- | --- |
| `is_loopback_host` 大小写 | IPv6 十六进制位大小写不敏感，`::FFFF:127.0.0.1` 原来被判成「已开放局域网」——安全边界说反。现在统一转小写并认 `::ffff:127.*`。 |
| 线程池构造 | 原来靠「先 setKeepAliveTime 再 allowCoreThreadTimeOut」的顺序才不崩。改成一次给全参数的 `ThreadPoolExecutor` 构造，去掉顺序依赖。 |
| 磁贴不自退 | 加 `onTileRemoved() → stopSelf()`。系统只在磁贴被移除时解绑，收起面板不会。 |
| 卸载不卸磁贴 App | `uninstall.sh` 现在会调 `tile_uninstall`。注意：从管理器「移除模块」时脚本跑在模块目录已消失之后，那一步拿不到，需手动卸载。 |
| `grep` 二进制 cmdline | `uninstall.sh` 里对 `/proc/pid/cmdline` 用 `grep -q` 改 `grep -aq`。 |

测试：`test-lib.sh` 从 118 条增到 174 条、`test-install.sh` 从 39 条增到 46 条，
另加 10 条 JVM 用例。合计 299 + 10。

### 新增

- **隐藏桌面图标**。App 里多一个「桌面图标」开关。隐藏后桌面不再有图标，
  只剩磁贴，适合不想让桌面多一个图标的人。

  实现：桌面入口（MAIN + LAUNCHER）挂到 `activity-alias`（`.Launcher`）上，
  隐藏 = 关掉这个 alias。**不能直接关 MainActivity** —— 那样用户再也进不来
  设置页，也没法把图标恢复回去，等于把自己锁死。

- **磁贴长按打开设置页**。这是隐藏图标后的主要恢复入口；
  另有 `adb shell am start -n com.ruin.magpie.tile/.MainActivity` 兜底。

  实现上不能用 `TileService.onLongClick` —— **android-34 的 API 里根本没有这个方法**
  （只有 `onClick` / `onStartListening` / `onStopListening`）。长按时 SystemUI
  发的是 `ACTION_QS_TILE_PREFERENCES`，由 `MainActivity` 接住。

### 修了一个会让 App 装不上的构建缺陷

`tile-app/build.sh` 里原来是 `javac ... 2>&1 | grep -vE '...' || true`。
两个问题叠在一起：

1. 管道让 `$?` 变成 `grep` 的退出码，**javac 编译失败会被当成成功**，`set -e` 也不管用；
2. 过滤规则写宽了，把 `error:` 也一并滤掉。

结果：带编译错误也能打出 APK，dex 里只有部分类，装上去一启动就是
`ClassNotFoundException: Didn't find class "MainActivity"`。

现在 javac / d8 的输出先落文件、检查退出码、再过滤；另加两道自检：
每个源文件都必须产出对应 `.class`，dex 里必须能找到清单声明的
`MainActivity` 与 `MagpieTileService`，缺任何一个就拒绝产出 APK。

### 验证

- 禁用 alias 后 `resolve-activity -c LAUNCHER` → *No activity found*（图标消失）
- 同时 `am start -n .../.MainActivity` → `Status: ok`（不会锁死）
- 重新启用后 LAUNCHER 入口恢复

`test-lib.sh` 新增 4 条静态断言盯这件事：入口必须在 alias 上、
alias 要指向 MainActivity、MainActivity 自己不能带 LAUNCHER 类别、
磁贴长按的入口（`ACTION_QS_TILE_PREFERENCES`）必须有人接住。

磁贴 App versionCode 4 / versionName 1.2.0。

## v1.1 — 2026-11-24

加了一个可选的配套 App：把 Magpie 的启动/停止放进下拉控制中心。

### 新增

- **控制中心磁贴**（`com.ruin.magpie.tile`）。刷模块时可以用音量键选装：

  ```
    可选的配套 App
  - Magpie 磁贴：把「启动/停止」放进下拉控制中心
    它不是 magpie 本体，也不代理流量；只是一个开关，
    通过 root 调用本模块的启停脚本。不装也不影响网关运行。

    音量键上 = 安装，音量键下 = 跳过（15 秒不按则跳过）
  ```

  为什么必须做成独立 App：Magisk 模块本身不能声明 `TileService`，
  磁贴只能由已安装的 App 提供。

- **`magpie.service toggle`** 子命令：在跑就停、没跑就起。磁贴、快捷方式、
  Tasker 都用它。停止走同一条 `stop` 路径，`.user_stopped` 语义不变，
  看门狗不会把用户主动停掉的服务拉回来。

### 设计取舍

- **磁贴不主动弹 root 授权框**：`TileService` 在后台跑，弹不出系统对话框。
  所以 App 有一个极简界面，首次打开时请求授权——这是它存在界面的唯一理由。
  没授权就点磁贴，磁贴显示「需要 root」并置灰。
- **状态缓存 5 秒**：`/data/adb` 是 0700 root，App 读不到模块的 run 目录，
  状态也只能走 su。不缓存的话每次展开控制中心都要 fork 一次 su。
- **点击先显示「处理中」**：启动 magpie 要几秒，没有即时反馈用户会以为没点上。
- **su 路径不写死**：按 `su`、`/system/bin/su`、`/system/xbin/su`、`/sbin/su`、
  `/debug_ramdisk/su`、`/data/adb/ksu/bin/su`、`/data/adb/ap/bin/su` 依次尝试。
- **图标**：App 图标用 magpie 官方 512×512；磁贴图标转成白色剪影 + 透明背景
  （SystemUI 会给磁贴图标单色着色，彩色图会显示成黑块）。

### 安装时机

刷机时先试 `pm install`；失败（Magisk 刷机脚本跑在独立 mount namespace 里，
`pm` 不一定通）就落一个标记，开机后由 `service.sh` 补装。两条路径都失败时，
模块目录里的 `magpie-tile.apk` 仍可手动安装。

### 签名

密钥不进仓库。需要每个版本用同一把 key，否则用户更新会因签名不一致装不上。
存放两处互为备份：本机 `/workspace/magpie-keys/`、GitHub 私有仓库
（`KANGKKKKKKK/magpie-keys`，只有 AES-256 加密后的 `.enc`）。
CI 通过 `MAGPIE_KEYSTORE_B64` / `MAGPIE_KS_PASS` 两个 secret 取密钥，用完即删。

证书 SHA-256：`21:7C:AC:85:1F:9D:14:BE:98:68:09:03:97:17:DC:42:8A:FA:04:E1:B5:06:F6:8E:75:3D:18:5B:21:B0:0F:F6`

### 测试

- `test-lib.sh` 新增 4 条：磁贴 App 的版本比较（没装→装、同版本→跳过、
  旧版本→更新、已装更新→不动）。判错的两个方向都会伤到用户：
  该更新时不动（永远拿不到新版），不该动时重装（每次开机都装一遍）。
- CI 增加一步「磁贴 App 能编译」，不需要签名密钥。

## v1.0 — 2026-11-24

从 v0.2 起的判断逻辑、配置解析与周边脚本都过了一遍：修掉三处「配置写错却静默出错」
的缺陷，把重复实现收成一份，补上自动化检查。真机验证通过后定版为 v1.0。
五个套件共 222 条断言（39 + 13 + 40 + 20 + 110），桌面与真机各跑一遍全过。

`versionCode` 从 1023 跳到 1100：v1.x 另起一段，也保证更新通道不会因为
「v1.0 比 v0.9.3 数字小」而被判成旧版本。

### 修复

- **漏写端口不再污染状态**。`MAGPIE_ADDR=127.0.0.1`（漏端口）以前会被截成
  `PORT=127.0.0.1`，于是写出 `"apiPort": 127.0.0.1` 这种**非法 JSON**（面板
  `r.json()` 直接失败）、`apiUrl` 拼成 `http://127.0.0.1:127.0.0.1/v1`、
  `lanOpen` 误判为 `true`，模块列表那一行也变成
  `🟢 运行中 | 192.168.200.115:127.0.0.1`。现在端口统一按 1..65535 校验
  （`lib.sh` 的 `addr_port`），**不再静默退回默认值**：
  `magpie.service start` 直接拒绝并说明原因，`status.sh` 仍输出合法 JSON
  但把 `apiPort` 置 0、地址字段留空、新增 `configError` 说明错在哪，
  `action.sh` 拒绝启停与切网关，`doctor.sh` 在 `[2/9]` 直接报红。
- **IPv6 回环被当成局域网**。`[::1]:3425` 以前在三处都识别不了
  （`addr_host` 只做 `${1%:*}`，剥出 `[::1]` 匹配不上 `::1`），会被报成
  「已对局域网开放」。现在 `addr_host` 认识方括号、`is_loopback_host`
  统一判定 `127/8`、`localhost`、`::1`、`[::1]`，`action.sh` 的
  切换行为也跟着对。
- **`status.json` / `lastlog.txt` 直接覆盖**。面板每 5 秒 fetch 一次，
  写到一半就可能读到半份 JSON。改为同目录临时文件 → 设权限 → `mv` 原子替换，
  失败则保留旧文件；权限在 `mv` 之前设好，不留 644 的窗口。字符串字段
  统一经 `json_str` 转义（反斜杠、双引号），控制字符丢弃。
- **`MAGPIE_DNS` 里写错的项以前照样写进 resolv.conf**。旧的「校验」只查字符集，
  `abc`、`999.999.999.999`、`8.8.8` 都能过。现在按 IPv4/IPv6 格式逐条校验，
  非法项**跳过并在日志里逐个点名**（不是整份作废——一个笔误不该连累其余可用上游），
  一条都不合法时才保留旧配置。`magpie.service` 的 fallback 同步改成
  「不做半套校验」，避免两份实现再次漂移。
- **安装失败被显示成成功**。`action.sh` 的安装分支无论结果如何都 `exit 0`，
  失败码被吞掉。现在原样透传。
- **`magpie` 命令会把自定义配置覆盖回默认值**。`magpie-cli.sh` 无条件第二次
  source 硬编码路径的配置。改为只在 `magpie_resolve_conf` 什么都没找到时兜底。
- **`doctor.sh` 只认 `ss`**。精简系统没有这个 applet 时会报假红。
  现在依次退到 `netstat`、`/proc/net/tcp(6)`；`[7/9]` 的面板暴露判定改用推算出来的
  面板地址，`MAGPIE_WEB_ADDR` 留空而网关开在 `0.0.0.0` 时不会再漏报。
- **`MAGPIE_CONF` 终于真的生效**。README 一直写「按 `MAGPIE_CONF` → 数据目录 → 模块」
  查找，实际只有 `magpie.service`、`lib.sh`、`uninstall.sh`、`magpie-cli.sh` 认这个变量，
  `status.sh`、`doctor.sh`、`install.sh`、`action.sh`、`customize.sh` 都是硬编码路径，
  排障时指定的配置根本不生效。现在六处都认。
- **发版 tag 校验太松**。`release.yml` 用 `case` 的 glob 判断 `v[0-9]*.[0-9]*`，
  而 glob 里除 `.` 和 `[]` 之外都是通配符，`v1junk.2`、`v1.2.3.4.5`、`v0.9.` 都能过。
  现在按段显式校验（`lib.sh` 的 `is_valid_release_tag`，2..4 段纯数字），
  并由 `test-lib.sh` 覆盖，本地就能发现改坏。
- **看门狗不等开机完成**。等待只包住了「首次拉起」那个子 shell，看门狗循环照跑，
  理论上能在开机过程中抢先 `start` 一次，和首次启动撞车（后到的因端口被占而失败，
  白记一条「拉起失败」）。现在两条路径都走 `wait_boot_completed`；
  顺手改成有上限（默认 600 秒，`MAGPIE_BOOT_WAIT_SECS` 可调）——
  以前是无限 `until`，`getprop` 不可用时服务永远起不来。
- **`install.sh` 的 `M_TAG` 算了不用**，删掉。
- **服务会被调用者的进程组带走**（真机验证时发现）。`magpie.service start`
  启动的 `magpie serve` 留在调用者的会话里：从管理器 `[执行]`、Termux、
  或任何「命令跑完就清理子进程组」的宿主启动时，父进程一退出整组被收，
  表现为「提示已启动、二三十秒后自己没了」，还留下一串 `拉起失败` 的假象。
  现在启动时用 `setsid` 让服务进入独立会话；顺带把 PIDFILE 改到探测到真实
  pid 之后再写（部分 `setsid` 实现会 fork，`$!` 不是最终进程）。
  注意**不能加 `-c`**：busybox 的 `-c` 是「强制 fork」，util-linux 的 `-c`
  是「设置控制终端」，语义相反，在没有 tty 的环境里会直接启动失败。

### 结构调整

- **CA 证书包与日志轮转收进 `lib.sh`**。`magpie.service` 和 `magpie-cli.sh` 各自抄了一份
  指纹计算与合并流程，`rotate_log` 也是两份。以后改证书策略很容易漏一处，
  而两处指纹算法一旦漂移，症状是「证书明明变了却不重建」——极难查。
  现在实现只有一份，两个脚本只留调用与措辞。顺带修了一处真实缺陷：
  以前是「比对时算一次指纹、写 stamp 时再算一次」，两次之间目录 mtime 变了，
  就会写进一个永远匹配不上的 stamp，导致每次启动都白重建一遍。
- **`service.sh` 的 lib.sh 提到顶层 source**。原来写在看门狗子 shell 里，
  子 shell 里的函数定义回不到父 shell，`rotate_log` 用不上公共实现。

### 行为变更

- **看门狗巡检间隔 20 秒 → 30 秒**（`MAGPIE_WATCH_INTERVAL` 可调）。退避序列随之变成
  30/60/120/…，最长仍封顶 10 分钟。改间隔不用再改测试：`test-watchdog.sh` 从
  `service.sh` 里读这个值来算期望。
- **面板数字会动了**。以前 `status.json` 只在启停/切网关/局域网地址变化时重写，
  面板每 5 秒轮询同一份不变的文件，运行时长和内存是启停那一刻的快照。
  现在看门狗每 5 轮（默认约 2.5 分钟）刷一次，用的是新增的
  `status.sh --webonly`：只重写 webroot 下两个文件，不碰模块描述
  （也就不会每 30 秒去调一次 `ksud` / 重写 `module.prop`）。
  仍然不是实时监控，状态栏的「数据 HH:MM:SS」写明上次写入时刻。
- **下载超时拆成两个**。以前 `wget -T 60` 与 `curl --max-time 600` 语义不同却被当成同一个数：
  `-T` 是停滞超时（只要还有数据就一直下），`--max-time` 是总时限。
  慢网下 87 MB 走 curl 需要 >145 KB/s，反而更容易被掐；wget 那侧又没有总上限。
  现在 `MAGPIE_DL_STALL`（默认 60 秒，停滞）与 `MAGPIE_DL_TIMEOUT`（默认 30 分钟，总时限）
  分开，wget 分支用 `timeout` 补上总上限（没有 `timeout` 时退回只有停滞超时）。

### CI

- **加 shellcheck**。只查生产脚本、排除 `SC1090`/`SC1091`（动态 source，刻意如此）：
  测试文件里 70 条告警有 59 条来自 `a && b || c` 这类刻意的写法，一并对齐只会养成
  「红了就加 disable」的习惯。逐处例外用内联 `# shellcheck disable=` 并写明理由，
  共四处：`pidof` 的多 pid 必须分词（加引号反而杀不掉）、`busybox wget` 的命令名要分词、
  顶层 `return 0 || exit 0`、单元素 `for` 保留扩展性。
  顺手按它的提示修了四处：`lib.sh` 里用 `ls | wc -l` 数证书文件（改 `find`）、
  `magpie.service` 的 `A && B || C` 改成 if-else、`ls -l /proc/…/fd | grep`
  改成读链接（`readlink`）、`ls …/magpie-bun | head -1` 改成 for 循环。

### 测试

- `test-lib.sh` 新增 8 条：CA 证书包合并（含「失败时不覆盖旧包」「不留临时文件」）
  与日志轮转，这两块刚从两份实现收成一份，得有东西盯着。
- `test-service.sh` 新增 1 条：`magpie.service start` 拉起的进程必须落在
  自己的会话里（sid ≠ 调用者 sid）。这条直接拦上面那个「启动后自己没了」。
- `test-watchdog.sh` 改按 `service.sh` 里的 `#<<< WATCHDOG-BODY` 标记抽循环体，
  不再靠缩进猜（这次给等待函数加了个 `until…done` 之后，旧写法抽出来是空的）；
  并新增自检：抽到几行、必须含 `user_stopped` / `magpie_bin_usable` / `rotate_log`。
- `test-service.sh` 新增 2 条：看门狗必须在循环前等开机；`getprop` 一直不报完成时，
  等满上限后仍要继续启动。
- 新增 `tests/test-lib.sh`：地址切分、端口边界、回环判定、IPv4/IPv6 格式、
  DNS 过滤、JSON 转义、发布 tag 形状，表驱动 102 条。
- `tests/make-fixtures.py` 支持 `--base`，换端口跑测试不再出现假失败
  （以前清单里写死 `:8899`，用 18999 会有 15 条失败）。
- `tests/test-install.sh` / `test-action.sh` 启动时提示夹具要用同一地址生成。

## v0.9.2 — 2026-11-23

v0.9.1 的真机复查补齐。主链路在重启后已实测通过：`/etc/resolv.conf` 覆盖挂上
（与模块文件同一 inode）、开机日志报 `DNS 上游 ...`、`doctor` 的 `[8/9]` 变绿、
原生通道与 GitHub 同步都恢复正常。这一版只收紧两处边界。

### 修复

- **`MAGPIE_DNS` 写空时不再把 DNS 抹掉**。以前生成逻辑只写出 `options` 一行，
  覆盖文件里就没有 `nameserver` 了 —— 等于把上游删光，Go 又会退回
  `127.0.0.1:53` / `[::1]:53`。现在两处生成都要求至少有一条 `nameserver`：
  `sync_resolv_conf` 不合格就直接返回、不动现有配置并告警；`customize.sh`
  先写临时文件再校验，不合格保留模块自带那份。
- **`lib.sh` 缺失时也能生成 DNS**。fallback 分支此前只补了 `lan_ip`，
  `magpie_resolv_body` 是空的，结果会生成空文件并报「MAGPIE_DNS 为空或格式不对」——
  把原因指向配置，而真实原因是依赖文件缺失。现在 fallback 里带上同样的实现。

### 其他

- 措辞校正：本体不是「静态编译」，而是**不链接 libc 的 Go 静态 PIE**
  （进程映射里有 linker64、没有 libc.so → `cgoAvailable == false`）。结论不变，
  但仍按实测改了 README、README_EN、CHANGELOG 和各脚本注释里的说法。
- `tests/test-service.sh` 增加一条断言（`MAGPIE_DNS` 为空时保留原有 DNS），13 项全过。

## v0.9.1 — 2026-11-23

修一个从 v0.2 起就存在的失效配置：**`MAGPIE_DNS` 从来没真正生效**。原生 Go 通道
（DeepSeek、OpenAI、Anthropic、Gemini 这些直连供应商，以及 GitHub 同步）在 Android 上
一律 `lookup ... on [::1]:53: connection refused`；走 Bun 插件的供应商不受影响，
所以表现为「有的模型能用、有的不能用」。

### 修复

- **DNS 改用 Magisk 覆盖的 `/etc/resolv.conf`**。magpie 本体是不链接 libc 的 Go 静态 PIE
  （`cgoAvailable == false`），只能走纯 Go 解析器；它只认 `/etc/resolv.conf`，Android
  上没有这个文件时会把服务器置为 `127.0.0.1:53` / `[::1]:53`，而这两个地址没人监听。
  现在模块自带 `system/etc/resolv.conf`，`magpie.service` 启动时按 `MAGPIE_DNS` 重写它，
  开机后由 Magisk 挂成 `/etc/resolv.conf`。不启动本地 dnsmasq，不会和系统热点抢 53。
- **删掉无效的 `DNS_LOCAL_HOSTNAMES`**。Go 标准库没有这个变量，magpie 本体里也搜不到
  （整个二进制零命中），v0.9.0 及以前注入的 `export` 只是看起来在工作。README、
  配置注释里的相关说法一并改正。
- **自检加一项 `[8/9] DNS 解析`**：看 `/etc/resolv.conf` 在不在、上游能不能解析
  `api.deepseek.com`，失败时直接给出下一步；其余检查项顺延成 `x/9`。
- `magpie` 命令在 `/etc/resolv.conf` 缺失时直接提示，不再让它以 `lookup ... refused`
  这种难以归因的方式失败。

### 注意

- `system/etc/resolv.conf` 由 Magisk 在开机时挂载，**装或更新这一版后要重启一次手机**；
  之后改 `MAGPIE_DNS` 只需 `magpie.service restart`（若 doctor 显示上游还是旧的，再重启一次）。
- 触发这一版的原因见 issue #1（报告人 `becausemadoka`：逐文件核对 Go 解析器行为，
  并给了完整的验证脚本）。

## v0.9.0 — 2026-11-18

`[执行]` 从「一键启停」升级成**音量键菜单**：不进终端也能切网关、启停、看地址。

### 新增

- **`[执行]` 是菜单，不再是单纯的开关**。点开后用音量键导航：
  **音量下 = 换一项，音量上 = 执行**，60 秒没按键自动退出。

  ```
  ───────────  Magpie  ───────────
   状态  运行中
   网关  局域网 · 其他设备可连接
   地址  192.168.1.5
  ────────────────────────────────
     1  切到「仅本机」
   ▸ 2  查看接入信息
     3  重启
     4  停止
     5  启动
     6  打开面板
     7  退出
  ────────────────────────────────
   音量下 换一项 · 音量上 执行
   60 秒没按键就自动退出
  ```

- **切换网关监听范围**（菜单第 1 项）：只改 `magpie.config` 里的 `MAGPIE_ADDR` 与
  `MAGPIE_WEB_ADDR` 两行，其余原样保留（有逐字节回归测试）。服务在跑就顺势重启一次
  让新地址生效。用途是「偶尔开热点给平板用」：开热点时切到局域网，平时切回仅本机，
  不必再手动编辑配置。
- **菜单里直接给出接入信息**（第 2 项）：本机与局域网两套地址分行列出，「其他设备
  （平板 / 电脑）这样填」直接给出该填的接口地址和取密钥的位置。
- **退出时关掉 `[执行]` 窗口**：Magisk 跑完 `action.sh` 不会自己收起那个文本框，页面会
  停在原地。选 7 退出时按一次返回键关掉浮层，回到模块列表。只在「确实是在模块管理器里
  跑」时才按（沿父进程找 5 层 + 前台包名双判），终端、adb、别的 App 里跑绝不动手。
- **命令行子命令**，菜单里能做的不进菜单也能做：

  ```sh
  sh action.sh            # 音量键菜单（与点 [执行] 相同）
  sh action.sh status     # 接入信息
  sh action.sh gateway    # 当前网关 + 配置里那两行
  sh action.sh lan|local  # 切到局域网 / 切回仅本机
  sh action.sh start|stop|restart
  sh action.sh panel      # 打开面板
  ```

### 改进

- **读不到音量键时不把人卡住**：`getevent` 用不了（老设备、受限环境）时退回原来的
  一键启停——在跑就先报信息再停止，没跑就启动并开面板，同时说明可以用子命令。
- **界面按环境自适应**：终端里（Termux / adb shell）原地重画，整个菜单不动、只有 `▸`
  换位置；Magisk 的文本框不认光标控制符，只画一次菜单，之后每按一次音量键追加一行
  `→ 4  停止`，执行动作后再整屏画一次。想强制某种方式：`MAGPIE_ACTION_TTY=1` /
  `MAGPIE_ACTION_NOTTY=1`。
- **音量键顺带改了媒体音量**：菜单退出时还原成进来时的值，不在系统里留下副作用。
- 菜单文案精简：去掉重复的「重启 magpie / 停止 magpie」（标题已经写了 Magpie），
  中文按双宽对齐，`网关 / 面板 / 进程 / 提示` 标签与值分列对齐。

### 修复

- **端口解析没有校验**：配置写成 `MAGPIE_ADDR="0.0.0.0"`（没带端口）时会拼出
  `http://127.0.0.1:0.0.0.0/v1` 这种坏链接。现在非纯数字一律退回默认端口。
- **「60 秒没按键」实际会拖到一分半**：原来靠数 `sleep 0.1` 的次数，而每轮还要跑
  `wc`/`grep`，单轮约 0.15 秒。改成按真实时间校表，实测 3 秒超时正好 3 秒。
- **`read_key` 用命令替换取值**：`$(read_key …)` 是子 shell，`KEYN` 的推进带不回来，
  同一次按键会被反复读到。改成写 `KEYLAST` 变量。
- **松开音量键被当成一次按下**：`KEY_VOLUMEDOWN` 这个键名本身就含 `DOWN`，只按子串
  匹配会把 `UP` 事件也算进去。现在比对值那一列必须是 `DOWN`（同时兼容无标签的
  `0072`/`0073` 原始码）。
- **`lib.sh` 缺失时报 `magpie_running: not found`**：兜底分支只定义了 `lan_ip`。
  现在补上 `magpie_main_pid` / `magpie_running` 的最小实现。
- **`action.sh start` 与菜单里选「启动」输出不一致**：前者直接转发服务脚本的原始输出。
  现在统一走 `do_start` / `do_stop` / `do_restart`，退出码仍反映最终状态。
- **按键日志残留**：被强杀会留下 `run/magpie-keys.*`。启动时清理所属 PID 已不存在的
  旧文件；`getevent` 起不来时 0.3 秒内报错退出，不再空等 60 秒。
- **`ip` / `pidof` 可能不在 PATH 里**：精简环境下局域网地址探测会静默失败，
  现在先补上与 `magpie.service` 相同的 PATH 前缀。

### 测试

- `tests/test-action.sh` 重写，从 13 条扩到 **40 条**：安装分支、退路一键启停、
  `status` / `gateway` / 未知子命令、音量键解析（按下 / 松开 / 无标签原始码）、
  两种界面模式（终端有光标控制符、非终端一个都没有）、收尾关窗口的三条决策路径、
  管理器包名白名单。
- 隔离更严：沙箱副本里**把 `SERVICE` 钉死在测试目录**，所有 source 处强制
  `MAGPIE_ACTION_LIB=1`。这两处是写测试时踩出来的真问题——早先版本会顺着 `$MODDIR`
  找到仓库里真实的 `scripts/magpie.service`，把正在运行的服务重启一遍。
- 四个套件合计 **98 条**（安装 39 / 看门狗 8 / 执行 40 / 进程 11），全部通过。

## v0.8.1 — 2026-11-16

### 修复

- **发版工作流可被输入注入**。手动触发发布时，`tag` 输入被直接拼进 shell 脚本
  （`TAG="${{ github.event.inputs.tag }}"`），输入里带引号或分号就能在 runner 上执行
  任意命令，而这个工作流有 `contents: write`。现在输入经环境变量传递并校验格式，
  同时**按指定的 tag 检出代码** —— 以前只拿它做命名和版本校验，打出来的是当前分支的包。
- **开机自启在首次开机时会彻底失效**。`service.sh` 的所有日志重定向都指向
  `run/watchdog.log`，而创建 `run` 的逻辑在 `magpie.service` 里。目录不存在时重定向
  直接失败、命令根本不会执行：本体装好但还没手动启动过就重启的手机，服务起不来，
  看门狗也拉不动。现在开局先建目录，建不出来就丢弃日志但照常尝试启动。
- **`magpie.service` 在 `data` 目录不存在时写不了 `web.key`**，面板访问密码每次重启都
  换一个，旧链接失效。目录创建已提到写密钥之前。
- **安装/回滚收到 Ctrl-C、TERM 时会一边丢锁一边继续跑**。原先
  `trap 'release_lock' EXIT INT TERM` 只放锁不退出，脚本继续下载、继续替换二进制，
  此时另一个安装已经可以进来。现在信号处理器收掉下载子进程、放锁、以 130 退出；
  下载改为后台 + `wait`，否则 shell 要等前台命令结束才跑 trap，87 MB 下到一半得干等。
- **过期锁清理的竞态**。两个进程同时判定锁已过期、各自 `rm -rf` 再 `mkdir`，会同时
  认为自己拿到了锁。现在用原子 `mv` 抢旧锁，只有一个能成功。
- **`stop` 在主进程已消失时提前返回**，跳过后面的 MCP 孤儿清理：主进程崩溃/被强杀后，
  子进程留在后台，反复发生时越积越多。现在无论主进程在不在都会收一遍残留。
- **启动前先清 MCP 孤儿**：按命令行里的 ` mcp ` 识别，不误杀用户正在跑的
  `magpie update`、`gateway-key` 等命令。
- **自定义 `magpie_path` 没被所有脚本认到**：`magpie` 命令包装器和卸载脚本写死
  `/data/adb/magpie`，改过路径的用户会出现「命令找不到本体」「卸载后二进制、密钥、
  用量记录全留在自定义目录」。两者现在都按配置解析；卸载还会顺手清掉默认目录里的旧
  残留，并对清理路径做安全校验（拒绝 `/`、`/data/adb`、`/sdcard` 等）。
- **发版时的 `update.json` 同步**：原先在检出出来的（可能是旧 tag 的）提交上改文件再
  推 `main`，非快进就失败；发旧版本还可能把更新通道倒退。现在在 `main` 的工作树上改，
  先比 `versionCode`，推送被拒时对齐重试。
- **CI**：新增 `.github/workflows/ci.yml`，推 `main` 与 PR 都跑语法检查和全部测试；
  发版工作流打包前也先跑一遍测试（以前只校验 zip 结构）。

### 测试

- 新增 `tests/test-service.sh`（11 条）：开机 `run` 目录缺失、`stop` 收孤儿、
  `start` 只清 MCP 孤儿、自定义路径下 `magpie` 命令的位置。
- `tests/test-install.sh` 增加一条信号用例（收到 `TERM` 立即退出、锁已释放、不落盘），
  共 39 条。四个套件合计 71 条。
- 新增的用例先对着旧代码跑过一遍，确认能复现上述问题（旧代码 7 条失败）。

## v0.8 — 2026-11-16

### 新增

- **模块负责装本体**。以前要自己找 magpie 二进制的文件、复制、改权限；现在点一下就行。
  新增 `scripts/install.sh`：检测 → 提示将装什么 → 下载 → 校验 → 部署 → 自检 → 刷新状态。
  - 来源是 magpie 自己的更新端点 `https://usemagpie.ai/api/latest`（`magpie update` 用的同一个），
    资产名 `magpie-cli-android-arm64`。下载优先厂商 CDN，失败退回 GitHub。
  - 校验用清单给出的 `size` 与 `sha256`；`SHA256SUMS` 与 GitHub API 的 `digest` 与该值一致。
  - 先下到同文件系统的临时文件，校验通过才 `mv` 原子替换；替换前备份旧本体到 `bin/magpie.bak`。
  - 装完立刻跑 `--version` 自检；失败则回退，首次安装无备份可退时把样本移到 `bin/magpie.rejected`
    并报出摘要，正式路径不留「看起来已安装」的文件。
  - 互斥锁防并发安装；过期锁能自动清理；空间不足先拦下；目标路径拒绝落到共享存储或符号链接下。
- **`[执行]` 按钮在未安装时变成安装入口**：第一次点按打印版本/大小/来源，窗口内再点一次才下载
  （终端不可交互，所以不读 stdin）。
- **`doctor.sh` 的本体检查改成分状态**：未安装 / 存在但跑不起来 / 可用（含版本），
  并给出对应的修复命令。
- **`customize.sh` 刷入时检测本体**并说明后续怎么装（**不在刷机流程里联网下载**）。

### 修复

- **模块脚本拿不到 wget**。模块脚本被管理器或服务拉起时，`PATH` 里可能只有系统目录，
  那里既没有 `wget`，也没有 `awk`/`stat`/`sha256sum`。实测按这种方式运行安装器时
  「取不到更新清单」，而换一个 shell 上下文就正常 —— 这条会让**所有用户都装不上本体**。
  现在安装器开头像 `magpie.service` 一样把各 Root 方案的 bin 目录注入 `PATH`，
  并在 `wget` 不可用时回退到 busybox 的 `wget`（也可用 `MAGPIE_DL` 指定下载器）。
- **看门狗在本体缺失时会每 20 秒撞墙刷日志**。现在检测不到可用本体就直接跳过，
  只记一次日志并把巡检间隔拉到 5 分钟；拉起失败改为指数退避（20/40/80…最长 10 分钟）。
- **首次安装校验失败会留下坏二进制**。旧流程只走「用备份回退」，首次安装没有备份，
  于是坏文件留在了正式位置。现在首次失败会把样本挪到 `bin/magpie.rejected`。
- **临时文件写不进去**：`bin/` 目录原来只在部署时才创建，导致下载阶段就失败
  （全新安装必现）。现在下载前先建目录。
- **目标路径检查漏了子路径**：`/sdcard/xxx` 之前会落到符号链接检查，现在 `/sdcard/*` 直接拒绝。

### 变更

- 版本 `v0.7.1` → `v0.8`，`versionCode` 1008 → 1009。
- `update.json` 仍指向已发布的 v0.7.1；打 `v0.8` tag 后由工作流自动改写。

## v0.7.1 — 2026-11-15

### 修复

- **把 MCP 子进程误当成服务本体**。magpie 除了 `serve` 主进程，还会拉起同名的子进程
  （`magpie mcp vision` / `mcp search` / `mcp image`）。本机实测 `pidof magpie` 返回 4 个 PID，
  旧代码用 `pidof magpie | head -1` 取到的可能是子进程，导致：
  - 面板和自检里显示的 PID、运行时长、内存都是子进程的（内存少报 280 MB）
  - `stop` 只杀掉第一个 PID；若那是子进程，网关仍在监听，脚本却以为已经停了
  - 主进程崩溃但子进程残留时，看门狗认为「还在跑」，不会重启
- 现在统一用 `magpie_main_pid()`（命令行含 `serve` 的那个）判断运行状态，
  `stop` 先停主进程再清理全部残留子进程，内存报告为主进程加子进程的合计。

### 变更

- `scripts/net.sh` 改名 `scripts/lib.sh`，除局域网地址外增加进程识别函数。
- 版本 `v0.7` → `v0.7.1`，`versionCode` 1007 → 1008。

## v0.7 — 2026-11-15

### 新增

- **模块列表动态状态**：管理器里那一行现在直接显示状态和可用的接入地址，
  例如 `🟢 运行中 v0.1.4260 | 192.168.1.5:3425`，停止时是 `🔴 已停止 | 点 [执行] 启动`。
  不用点任何按钮就能看到该填进客户端什么。字体不支持 emoji 时把 `MAGPIE_ICON` 设为 `0` 退回 `[运行中]` 纯文本。
- **`scripts/lib.sh`**：局域网地址探测抽成公共实现，`magpie.service` / `status.sh` /
  `action.sh` / `doctor.sh` / `service.sh` 共用一份，不再各写一遍。
- **看门狗盯地址变化**：WiFi 重连、热点开关、切飞行模式之后，`run/lan.url` 与
  `module.prop` 的描述会自动刷新，不会让用户照着旧地址去连。
- **GitHub Actions 自动发版**：推 `v*` tag 或手动触发，云端打包、校验 zip 结构、
  发布 Release、回写 `update.json`。
- **英文文档** `README_EN.md`，中英文档顶部可互相切换。

### 修复

- **对外地址是过期快照**：`run/lan.url` 只在启动那一刻写一次。实测热点关掉之后，
  文件里还留着已经不存在的 `192.168.224.153`，用户照着连必然失败。现在 `action.sh`
  实时计算，看门狗每 20 秒发现变化就刷新。
- **`status.json` 的 `lanIp` 同样会过期**：现在每次 `status.sh` 都实时取。

### 变更

- 版本 `v0.6` → `v0.7`，`versionCode` 1006 → 1007。

## v0.6 — 2026-11-15

### 新增

- **自检脚本 `scripts/doctor.sh`**：一次跑完八项检查——本体、进程、端口、网关响应、面板与访问密码、网关密钥、CA 证书包、局域网暴露面、日志与磁盘。每项给结论和下一步怎么做。
- **`[执行]` 按钮打印接入信息**：动作执行前先列出 PID、网关地址、面板地址；开放局域网时补上可供别的设备使用的行外地址。
- **在线更新**：`module.prop` 增加 `updateJson`，指向仓库根目录的 `update.json`，管理器里可以直接收到新版本。
- README 增加徽章、架构图、接入前检查清单、验证连接一节与连接失败 FAQ。

### 修复

- **运营商级 NAT 被当成局域网地址**：`100.64.0.0/10` 只有运营商内网可达，之前会被选中并广播出去，手机走数据网络时等于报了一个谁也连不上的地址。现在排除。
- **局域网地址优先级的顺序**：优先 WiFi / 热点 / USB 网卡，跳过移动数据接口（`ccmni` / `rmnet` / `clat`）。此前热点开着时也可能报出数据网络的地址。
- **README 的面板说明**：`:3430` 是 magpie 自带的面板，模块自带的 `webroot` 面板需要 KernelSU WebUI / WebUI-X 才能打开。之前两者混为一谈，截图与地址对不上。

### 变更

- 版本 `v0.5` → `v0.6`，`versionCode` 1005 → 1006。

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
