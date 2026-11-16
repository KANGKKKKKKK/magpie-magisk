# 测试

三个脚本，都不碰真实运行的 magpie：所有目录都在临时位置，服务进程被桩替代。
合计 57 条断言（36 + 8 + 13），在桌面 Linux 与 Android 上各跑一遍都是全通过。

| 套件 | 断言数 | 测什么 |
| --- | --- | --- |
| `test-install.sh` | 36 | 安装器的 16 个用例 |
| `test-watchdog.sh` | 8 | 看门狗的决定逻辑 |
| `test-action.sh` | 13 | `[执行]` 按钮的分支选择 |

需要夹具的套件（install、action）要先起一个静态文件服务；watchdog 不需要。

## 看门狗决定逻辑

```sh
sh tests/test-watchdog.sh
```

把 `service.sh` 里看门狗的循环体抽出来，接一段沙箱前言，前台跑固定轮数，检查：

1. 本体缺失时**只记一次**日志、**不尝试拉起**；
2. 拉起一直失败时，失败计数累加、退避按 20/40/80… 递增；
3. 拉起成功时不报失败；
4. `run/.user_stopped` 存在时不拉起。

## `[执行]` 按钮的分支

```sh
python3 tests/make-fixtures.py /tmp/fx
(cd /tmp/fx && python3 -m http.server 8899) &
TEST_SRV=http://127.0.0.1:8899 sh tests/test-action.sh
```

4 个用例，只验分支选择，不验启停实现：

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

覆盖 16 个用例：

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
```

## 真机上的额外验证（不在 CI 里）

- 用真实清单跑过一次完整安装到沙箱目录：87 MB 从厂商 CDN 下载、sha256 与清单一致、
  部署后可执行且 `--version` 正常，随后沙箱整个删除。
- 真实本体全程未被触碰；测试期间没有重启服务。

## 已知缺口

- 没有覆盖「下载中途断网」：夹具是本地文件，断网场景需要额外的代理或断点工具才能模拟。
- 没有覆盖「下载中途断网」之外的网络异常（DNS 失败、TLS 被拦）在桌面侧的复现。
- 没有覆盖 arm32 / x86_64 设备：`check_arch` 会直接拒绝，但没有在真机上跑过非 arm64。
- 没有覆盖自定义 `magpie_path` 的完整安装（只覆盖了拒绝非法路径的分支）。
