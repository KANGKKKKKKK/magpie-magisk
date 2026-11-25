# 磁贴 App（com.ruin.magpie.tile）

把 Magpie 的启动/停止放进下拉控制中心。

它不是 magpie 本体，也不代理任何流量——只做一件事：通过 root 调用
`/data/adb/modules/magpie/scripts/magpie.service toggle`。

## 为什么需要一个 App

Magisk 模块本身**不能**注册快捷设置磁贴。`TileService` 必须由一个已安装的
App 声明，模块只能往系统里放文件。所以磁贴只能做成一个独立的小 APK，
由模块负责把它装上去。

## 它做什么 / 不做什么

| 做 | 不做 |
| --- | --- |
| 磁贴点击 → 启动或停止 magpie 服务 | 不含 magpie 二进制 |
| 显示当前状态（运行中 / 已停止） | 不代理、不转发流量 |
| 首次打开时请求 root 授权 | 不做任何配置（配置都在 `magpie.config`） |
| 「打开面板」跳转到 Web UI | 不联网 |
| 可隐藏桌面图标（只留磁贴） | 不常驻后台、不监听任何事件 |

## 安装方式

**推荐**：刷模块时选装。`customize.sh` 会用音量键问一次：

```
  可选的配套 App
- Magpie 磁贴：把「启动/停止」放进下拉控制中心
  ...
  音量键上 = 安装，音量键下 = 跳过（15 秒不按则跳过）
```

选了安装但刷机环境下 `pm` 装不上时，会落一个标记，开机后由 `service.sh` 补装。

**手动**：模块目录下就有 `magpie-tile.apk`，直接用文件管理器打开安装。

装完后还有两步：

1. 打开 App，点「授权 root」，在 Magisk 弹窗里允许。
2. 下拉控制中心 → 编辑 → 把 **Magpie** 拖出来。

磁贴不会自己出现在下拉栏里，这是 Android 的规则，绕不过去。

## 为什么磁贴自己弹不出 root 授权框

`TileService` 在后台运行，没有界面，弹不出系统授权对话框。
所以必须先打开一次 App 完成授权——这也是这个 App 有界面的唯一理由。

如果没授权就点磁贴，磁贴会显示「需要 root」并置灰。

## 隐藏桌面图标

App 里有个「桌面图标」开关。隐藏之后桌面不再有图标，只剩控制中心磁贴。

实现方式：桌面入口（`MAIN` + `LAUNCHER`）挂在 `activity-alias`（`.Launcher`）上，
而不是 `MainActivity` 本身。隐藏 = `setComponentEnabledSetting` 关掉这个 alias。

**为什么不用别的方式**：如果直接关掉 `MainActivity`，用户就再也进不来这个
设置页，也就没法把图标恢复回去——等于自己把自己锁死。

**恢复入口**（三选一）：

1. 长按控制中心里的 Magpie 磁贴 → 打开设置页
   （SystemUI 发 `ACTION_QS_TILE_PREFERENCES`，`MainActivity` 接住）
2. `adb shell am start -n com.ruin.magpie.tile/.MainActivity`
3. 任何能显式启动该 Activity 的方式（快捷方式 App、Tasker 等）

已验证：禁用 alias 后 `resolve-activity -c LAUNCHER` 返回 *No activity found*，
同时 `am start -n .../.MainActivity` 仍返回 `Status: ok`。

## 状态怎么读

`/data/adb` 是 `0700 root`，普通 App 连这一级都进不去，所以读不到
`/data/adb/magpie/run/` 下的任何东西 —— 「读状态」也只能走 `su`。
为了不让每次展开控制中心都 fork 一个 su，结果会缓存 5 秒。

（`run/` 目录自身的 mode 随模块创建时的 umask 而定，本机实测是 `0777`。
但这一级之上是 `0700`，所以对普通 App 来说仍然不可达。）

## 已知限制：进程被冻结时磁贴不会刷新

MIUI / HyperOS 上的冻结类模块（本机是 NoActive）会在本 App 空闲几十秒后
把整个进程冻住（`cgroup.freeze=1`）。冻结期间：

- SystemUI 展开控制中心时发的 `onStartListening` 到不了 App；
- `su` 根本不会执行（不是「查到了旧状态」，是压根没查）；
- 磁贴停在最后一次画出的画面上，于是看起来「和实际运行状态不符」。

实测：冻结状态下 `cmd statusbar expand-settings` 后，App 侧一行日志都没有；
手动 `echo 0 > /sys/fs/cgroup/uid_XXXX/pid_YYYY/cgroup.freeze` 解冻后立刻正常。
**这个问题在 App 里修不了**，必须在冻结白名单里放行
（NoActive：`whiteUidSet` 加本 App 的 UID，改完重启生效）。

App 侧能做的只有「不把已经知道的状态丢掉」：拿不到 `Tile` 对象时按
60/150/400/900 ms 重试；`su` 输出认不出来时沿用上次状态，而不是画成「已停止」。


su 的路径不写死：按 `su`、`/system/bin/su`、`/system/xbin/su`、`/sbin/su`、
`/debug_ramdisk/su`、`/data/adb/ksu/bin/su`、`/data/adb/ap/bin/su` 的顺序试，
哪个能跑通就用哪个。

## 构建

```sh
export MAGPIE_KEYSTORE=/path/to/magpie-tile.jks
export MAGPIE_KS_PASS='...'
sh tile-app/build.sh
```

依赖：`aapt`、`zipalign`（apt 的 aarch64 版即可）、`javac`、`d8`、`apksigner`
（后两个来自 Android build-tools，是 Java 程序，跨架构可用）、`android.jar`。

**注意**：`aapt` 必须用正式平台（android-34），不能用 SDK 里那种
`android-37.0` 的 preview jar——它没有完整属性表，连 `android:exported`
都会报 "No resource identifier found"。

## 签名密钥

**每个版本必须用同一把 key 签名**，否则用户更新时会因为签名不一致装不上，
只能先卸载（卸载会丢数据）。

密钥不进仓库。需要放在两个地方互为备份：

1. 本机 `/workspace/magpie-keys/magpie-tile.jks`（口令另存）
2. GitHub 私有仓库

丢了这把 key，后续版本的 APK 就没法和已装的兼容。

## 与 BoxProxy 磁贴的差别

BoxProxy 是 VPN App，磁贴和业务在同一进程，读状态是读内存，几乎零成本，
所以它敢在磁贴里直接启停。

magpie 是独立的 Go 进程，状态在 root 私有目录里，磁贴每次都要过一趟 su
（约 100–300ms）。所以这里多了 5 秒缓存，点击后也先显示「处理中」再执行。
