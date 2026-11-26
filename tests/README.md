# 测试

五套脚本都在临时目录运行，并用桩替代服务进程；不会操作真实运行的 magpie。
当前文档计数为 427 条断言（77 + 13 + 43 + 57 + 237），另有 47 条 JVM 用例（`tests/jvm/`：`ClassifyTest` 13 条判定磁贴状态，`SelfCheckTest` 28 条判定自查结论，`ShellTest` 6 条真实进程回归）。

- **桌面 Linux**：本次修复后以 dash 和 bash 分别运行五套，均为 427 条通过、0 失败；另有 47 条 JVM 用例通过。
- **突变检验**：把安装器换回旧黑名单、把磁贴判据换回旧 `sed` 范围后，分别有 7 / 8 条断言失败；计数校验在「合计写错、分项仍对」时也会失败。这些用例不是只按新实现写的。
- **真机 Android**：`test-lib` / `test-watchdog` / `test-service` 可直接运行，会自动选择可写临时目录；`test-install` 与 `test-action` 需要静态文件服务，设备上没有 `python3` 时跑不了。此前一次 mksh + toybox 对这三套的实测记录依次为 108 / 13 / 20；这是历史结果，不代表当前版本已在 Android 上全套重跑。`test-lib` 中两项 JSON 校验因缺少 `python3` 而显示 `SKIP`，**SKIP 不等于 PASS**。

| 套件 | 断言数 | 测什么 |
| --- | --- | --- |
| `test-install.sh` | 77 | 安装器的 21 组用例 |
| `test-watchdog.sh` | 13 | 看门狗的决定逻辑（含循环体抽取自检） |
| `test-action.sh` | 43 | `[执行]` 菜单：安装分支、退路一键启停、子命令、按键解析、两种界面模式、收尾关窗口、白名单外路径的就绪拦截 |
| `test-service.sh` | 57 | 进程清理、开机目录、配置路径、DNS 生成、状态输出与配置来源、看门狗等开机、服务脱离调用者会话 |
| `test-lib.sh` | 237 | `lib.sh` 纯函数：地址切分、端口边界、回环判定（含 IPv6 大小写）、IPv4/IPv6 格式、DNS 过滤、JSON 转义、发布 tag、CA 合并、日志轮转、安装/卸载路径白名单、磁贴入口对账、用户配置生成 |

发布校验另有 `python3 tests/test-release-zip.py` 的 33 个测试（不计入上面的五套断言数），使用离线工具桩验证 ZIP 安全、证书判定、APK 元数据和构建失败路径；不能替代真实签名/验签。

需要夹具的套件（install、action）要先起一个静态文件服务；watchdog、service、lib 不需要。
换端口跑时，夹具必须用同一地址生成，否则清单里的下载地址对不上，会看到一堆假失败：

```sh
TEST_SRV=http://127.0.0.1:18999
python3 tests/make-fixtures.py /tmp/fx --base "$TEST_SRV"
```

## lib.sh 的纯函数

```sh
sh tests/test-lib.sh
```

以表驱动为主，直接 source `scripts/lib.sh`。路径与磁贴入口回归只在临时沙箱内操作文件，并用 `pm` 桩验证，不触碰真实系统路径或包。还覆盖：

1. **地址切分**：`127.0.0.1`（漏端口）、`127.0.0.1:0`、`:65536`、`[::1]:3425`
   分别该被切开还是判错 —— 这条正是「漏端口写出非法 status.json」的入口；
2. **回环判定**：`127/8`、`localhost`、`::1`、`[::1]` 都算仅本机；
3. **IP 格式**：`abc`、`999.999.999.999`、`8.8.8`、`01.2.3.4`、`1::2::3` 都要被拒，
   合法的 IPv4/IPv6（含 `::ffff:1.2.3.4`）要放行；
4. **JSON 转义**：引号、反斜杠、换行不能把 `status.json` 变成非法 JSON；
5. **安装/卸载路径**：两者使用同一默认拒绝白名单，只允许本模块的两个目标目录及子目录；非白名单路径、路径归一化异常和符号链接均拒绝。安装器 `status/check/plan/install/rollback` 每个入口都验证，沙箱断言确保拒绝前不创建目标、不执行目标下的本体；
6. **磁贴 launcher 对账**：只把目标包、User 0 的 `disabledComponents` 小节内完整类名视为已隐藏；测试覆盖空集合不打印标题、列表尾没有空行、`enabled` 或相邻小节、其他包、其他用户、完整类名精确匹配，以及 `pm dump` 失败/空输出时补做幂等 disable。

路径回归只在临时沙箱中运行。安装器基础用例会改写临时 `lib.sh` 副本中的路径 helper，使它只允许对应沙箱；新增白名单回归则直接测试真实 helper。该夹具不会改生产文件，生产脚本没有路径绕过开关。

## 看门狗决定逻辑

```sh
sh tests/test-watchdog.sh
```

把 `service.sh` 里看门狗的循环体抽出来，接一段沙箱前言，前台跑固定轮数，检查：

1. 本体缺失时**只记一次**日志、**不尝试拉起**；
2. 拉起一直失败时，失败计数累加、退避按 20/40/80… 递增；
3. 拉起成功时不报失败；
4. `run/.user_stopped` 存在时不拉起。

抽取按 `service.sh` 里的 `#<<< WATCHDOG-BODY` / `#>>> WATCHDOG-BODY` 两个标记走，
不靠缩进猜。以前是「从 `sleep "$_wait"` 到第一个两空格缩进的 `done`」——
给等待函数加个 `until…done` 之后，抽出来就变成空的了，而且失败信息会指向
「没有记录」「没有拉起」，看不出根因。现在先自检抽到多少行、是否含关键行，
再往下跑断言。（`sleep "$_wait"` 故意留在标记外面：测试里 `_wait` 会涨到几百秒，
真睡下去会把测试拖成几分钟。）

## `[执行]` 按钮的分支

```sh
python3 tests/make-fixtures.py /tmp/fx
(cd /tmp/fx && python3 -m http.server 8899) &
TEST_SRV=http://127.0.0.1:8899 sh tests/test-action.sh
```

这一节是整套 14 组里的 4 个「分支选择」用例，只看选了哪条路，不验启停实现
（启停、子命令、按键解析、界面模式在后面的组里）：

1. 本体缺失 → 进安装流程，**不调用启停**，也不提前下载；
2. 本体损坏 → 同样进安装流程；
3. 本体就绪且服务在跑 → 进停止分支（进程判定是桩，恒为「在跑」，
   所以停止循环必然超时，此时如实报失败才算对）；
4. 本体就绪但服务没跑 → 进启动分支。

隔离的关键是两处：`action.sh` 与 `install.sh` 的 `CONF` 都要改指沙箱配置，
`magpie_running` 必须换成桩 —— 真实 magpie 就在跑，不可能凭空消失。

## 本体安装器

需要一个静态文件服务来提供夹具。

```sh
python3 tests/make-fixtures.py /tmp/fx
(cd /tmp/fx && python3 -m http.server 8899) &
TEST_SRV=http://127.0.0.1:8899 sh tests/test-install.sh
```

覆盖 21 组用例（表格即清单）：

| # | 用例 |
| --- | --- |
| 1 | 未安装时状态为 `missing` |
| 2 | `plan` 能解析出版本与大小 |
| 3 | 不带 `--yes` 只打印方案，不下载 |
| 4 | 二次确认后真正安装：可执行、内容正确、记录写入、锁释放 |
| 5 | 已就绪时默认不覆盖，文件摘要不变 |
| 6 | `status` 报 `ready` 且版本正确 |
| 7 | sha256 不匹配拒绝部署，不留正式文件、不留临时文件 |
| 8 | 大小不符拒绝部署 |
| 9 | 能下载但跑不起来：自检拦住，正式位置不留文件，样本另存 `magpie.rejected` |
| 10 | 已有损坏本体：识别 `broken`，重装可修好，留下备份 |
| 11 | `rollback` 能退回 |
| 12 | 拒绝装到共享存储（`/sdcard/…`） |
| 13 | 清单取不到时错误可读（`install` 与 `plan`） |
| 14 | 并发安装被锁拦住 |
| 15 | 过期锁能清理，清理后安装成功 |
| 16 | `PATH` 里没有 `wget` 时靠 busybox 兜底（Android）/ 给出可读失败（桌面） |
| 17 | 收到 `TERM` 时立刻退出：锁已释放、没有落盘（用一个只连不应答的服务器把下载卡住） |
| 18 | `status`、`check`、`plan`、`install`、`rollback` 入口均先拒绝非白名单路径，不创建目标、不执行目标下的本体 |
| 19 | 拒绝目标目录、二进制、备份、安装记录、锁和临时清单文件中的符号链接；缺少公共路径校验时失败关闭 |

## 进程清理、开机目录与配置路径

```sh
sh tests/test-service.sh
```

断言数见上方套件表。覆盖几个曾经出问题、但纯逻辑测试看不出来的地方：

1. **首次开机 `run` 目录还不存在**：`service.sh` 的所有日志重定向都指向
   `run/watchdog.log`，目录不在时重定向会失败、命令根本不会执行 —— 结果就是永远起不来。
   用例把 `run` 删掉后跑一次，检查目录被建出来、服务确实被调用。
2. **`stop` 在主进程已消失时**：仍要清掉 MCP 孤儿进程（原来会在「未在运行」处提前
   return，孤儿子进程留在后台越积越多）。
3. **`stop` 在主进程存在时**：主进程和孤儿都要收掉。
4. **`start` 前只清 MCP 孤儿**：按命令行里的 ` mcp ` 判断，用户手上正在跑的
   `magpie update`、`gateway-key` 不会被误杀。
5. **自定义 `magpie_path`**：`magpie` 命令读的是配置里的目录，不是写死的默认路径。
6. **`start` 按 `MAGPIE_DNS` 生成 `resolv.conf`**：Go 静态 PIE 只认这个文件；
   配置被写空时不能把已有的 `nameserver` 抹掉（否则又退回 `127.0.0.1:53`）。

进程判定全部换成桩，占位进程用 `sleep` 顶替，跑完即收，不接触真实 magpie。

## 在 Android 上跑

Android 上还要额外验证「模块脚本被管理器拉起」那种环境 —— `PATH` 只有系统目录、
没有 `wget`。用一个最小的仓库镜像跑一遍：

```sh
R=/data/local/tmp/mgrepo
mkdir -p $R/scripts $R/tests
cp /data/adb/modules/magpie/scripts/install.sh $R/scripts/
cp /data/adb/modules/magpie/scripts/lib.sh     $R/scripts/
cp /data/adb/modules/magpie/service.sh         $R/
cp tests/* $R/tests/

# 把 PATH 收窄到系统目录，逼它走 busybox 兜底
env PATH=/product/bin:/system/bin:/system/xbin \
  TEST_SRV=http://127.0.0.1:8899 TEST_BASE=/data/local/tmp/mg-it \
  /system/bin/sh $R/tests/test-install.sh

env PATH=/product/bin:/system/bin:/system/xbin \
  TEST_BASE=/data/local/tmp/mg-wd \
  /system/bin/sh $R/tests/test-watchdog.sh

env PATH=/product/bin:/system/bin:/system/xbin \
  TEST_SRV=http://127.0.0.1:8899 TEST_BASE=/data/local/tmp/mg-act \
  /system/bin/sh $R/tests/test-action.sh

env PATH=/product/bin:/system/bin:/system/xbin \
  TEST_BASE=/data/local/tmp/mg-svc \
  /system/bin/sh $R/tests/test-service.sh
```

## 真机上的额外验证（不在 CI 里）

历史记录：曾用当时的真实清单在沙箱目录完成一次安装，下载约 87 MB，sha256 与清单一致，
部署后可执行且 `--version` 正常，随后删除整个沙箱。该记录只描述当时那一次安装，不代表当前清单大小，也不表示当前版本的所有测试套件都已在真机跑过。

该次操作没有触碰真实本体，也没有重启服务。

## 已知缺口

- 没有覆盖「下载中途断网」：夹具是本地文件，断网场景需要额外的代理或断点工具才能模拟。
- 没有覆盖「下载中途断网」之外的网络异常（DNS 失败、TLS 被拦）在桌面侧的复现。
- 没有覆盖 arm32 / x86_64 设备：`check_arch` 会直接拒绝，但没有在真机上跑过非 arm64。
- 没有覆盖自定义 `magpie_path` 的**完整安装**（只覆盖了拒绝非法路径的分支，以及
  `magpie` 命令是否读对目录）。
- 信号用例依赖 `python3` 起一个只连不应答的服务器；没有 `python3` 的环境会跳过这一条。
- 安装器用例在 x86_64 的 CI 上靠 `MAGPIE_ALLOW_ANY_ARCH=1` 绕过架构闸门（闸门本身
  只在真机上被验证过）；被绕过的只是 `uname -m` 那一句，其他逻辑照常测。

## 发布中断恢复

正式发布不覆盖任何已有资产。若 Actions 已上传草稿但尚未公开，在 `main` 手动运行 `release`，指定原 tag 并开启 `finalize_draft`：仅下载、验签和核对来源 commit，全部通过后才公开原草稿，不重建、不上传。若正式 Release 已成功、只是更新通道同步失败，则改用 `recovery_sync_only`，只修复 `update.json`。两种模式不能同时开启；缺少新校验清单或磁贴 APK 的历史版本（如 v1.2.4）不支持此恢复流程。

草稿元数据必须从认证的 Release 列表/ID 取得，不能依赖只按 tag 读取的端点。实际中断恢复验证也必须核对资产 ID 与摘要未改变。
