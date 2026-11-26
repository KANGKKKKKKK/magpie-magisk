package com.ruin.magpie.tile;

import java.util.ArrayList;
import java.util.List;

/**
 * 磁贴自查。
 *
 * <p>跑模块里的 scripts/tile-check.sh，把 key=value 翻成给人看的话。
 * 判定和文案都在这里，MainActivity 只管显示。
 *
 * <p>为什么调脚本而不是在 Java 里自己查：/data/adb 是 0700 root，读状态本来
 * 就只能走 su；而同一套判断 doctor.sh 也要用，写在脚本里两边才不会各说各话。
 */
final class SelfCheck {

    private static final String SCRIPT =
            "/data/adb/modules/magpie/scripts/tile-check.sh";

    /**
     * 模块目录。这里写字面量而不是引用 Shell.MODULE_DIR：
     * 那样本类会依赖 Shell（它引了 Android 的 Handler），
     * 就没办法在纯 JVM 上单测了。
     */
    private static final String MODULE_DIR = "/data/adb/modules/magpie";

    /**
     * 三种情形分开报：脚本在、旧模块没有脚本、模块不在。
     * fallback 也要带完成标记；不能在脚本失败后替它补 done=1。
     */
    static String command() {
        return "if [ -f " + SCRIPT + " ]; then sh " + SCRIPT
                + "; elif [ -d " + MODULE_DIR + " ]; then echo mod=1; echo old=1; echo done=1;"
                + " elif [ -r /data/adb/modules ] && [ -x /data/adb/modules ];"
                + " then echo mod=0; echo done=1;"
                + " else echo mod=unknown; echo done=1; fi";
    }

    private final List<String> lines;
    private final boolean executionSucceeded;
    private final String error;

    private SelfCheck(List<String> lines, boolean executionSucceeded, String error) {
        this.lines = lines;
        this.executionSucceeded = executionSucceeded;
        this.error = error == null ? "" : error;
    }

    static SelfCheck parse(String out, boolean executionSucceeded) {
        return parse(out, executionSucceeded, null);
    }

    /** 只收纯值，既不依赖 Android，也不依赖 Shell.Result 的实现。 */
    static SelfCheck parse(String out, boolean executionSucceeded, String error) {
        List<String> list = new ArrayList<>();
        if (out != null) {
            for (String l : out.split("\n")) {
                String s = l.trim();
                if (!s.isEmpty()) {
                    list.add(s);
                }
            }
        }
        return new SelfCheck(list, executionSucceeded, error);
    }

    /** 缺字段或重复字段都未知，不能从冲突的两份值中挑一份当作成功。 */
    private String get(String key) {
        String value = null;
        for (String l : lines) {
            if (l.startsWith(key + "=")) {
                if (value != null) return null;
                value = l.substring(key.length() + 1).trim();
            }
        }
        return value;
    }

    /** 按「执行完整性 → 服务 → root → 磁贴显示 → 冻结」的顺序给结论。 */
    List<String> report() {
        List<String> out = new ArrayList<>();
        if (!executionSucceeded) {
            if (error.contains("timed out") || error.contains("timeout")) {
                out.add("! 自查命令超时，本次结果未知");
                out.add("　稍后重试；超时前的输出不能作为健康结论");
            } else if ("no su".equals(error.trim())) {
                out.add("✗ 自查未能获得 root 执行环境，本次结果未知");
                out.add("　请在 App 中申请 root，并检查授权管理器");
            } else if (error.contains("interrupt")) {
                out.add("! 自查命令已中断，本次结果未知");
                out.add("　重新打开 App 后重试自查");
            } else {
                out.add("! 自查命令执行失败，本次结果未知");
                out.add("　请重试自查；若仍失败，请检查模块日志");
            }
            return out;
        }
        if (lines.isEmpty()) {
            out.add("! 自查没有返回输出，本次结果未知");
            out.add("　请重试自查；空输出不等于 root 被拒绝");
            return out;
        }
        if (!"1".equals(get("done")) || !"done=1".equals(lines.get(lines.size() - 1))
                || error.contains("[output truncated]")) {
            out.add("! 自查输出不完整（未收到有效的 done=1 完成标记），本次结果未知");
            out.add("　请重试自查；部分输出不能作为健康结论");
            return out;
        }

        String mod = get("mod");
        if ("0".equals(mod)) {
            out.add("✗ 没找到 magpie 模块");
            out.add("　磁贴靠模块里的脚本启停，先刷入模块");
            return out;
        }
        if ("1".equals(mod) && "1".equals(get("old"))) {
            out.add("! 模块是旧版，没有自查脚本");
            out.add("　更新模块后这里才有用");
            return out;
        }
        if (!"1".equals(mod)) {
            out.add("! 模块安装状态未知，无法确认模块目录");
        }

        String svc = get("svc");
        boolean serviceKnown = "running".equals(svc) || "stopped".equals(svc);
        if ("running".equals(svc)) {
            out.add("✓ Magpie 服务正在运行");
        } else if ("stopped".equals(svc)) {
            out.add("! Magpie 服务没有运行");
            out.add("　点一下磁贴就能启动");
        } else {
            out.add("! 读不到服务状态（未知），无法确认是否运行");
        }

        String installed = get("installed");
        if ("0".equals(installed)) {
            out.add("✗ 未检测到磁贴 App 的安装记录");
            out.add("　请确认 App 是否安装在当前用户");
            return out;
        }
        if (!"1".equals(installed)) {
            out.add("! 磁贴 App 安装状态未知，无法检查它的授权与进程");
            out.add("　安装查询未能确认，请稍后重试自查");
            return out;
        }

        String pol = get("magisk");
        if ("2".equals(pol)) {
            out.add("✓ root 已授权");
        } else if ("1".equals(pol)) {
            out.add("✗ root 被拒绝了");
            out.add("　Magisk → 超级用户，把「Magpie 磁贴」改成允许");
        } else if ("0".equals(pol)) {
            out.add("! root 还没授权");
            out.add("　点一次磁贴，在弹窗里允许");
        } else {
            // Magisk/sqlite 是可选项，其他 root 方案下不可用并非自查失败。
            out.add("· Magisk 授权记录未知（非 Magisk 或查询不可用），跳过该项");
        }

        String inqs = get("inqs");
        if ("0".equals(inqs)) {
            out.add("! 磁贴不在控制中心");
            out.add("　在控制中心编辑里把 Magpie 拖出来");
        } else if (!"1".equals(inqs)) {
            out.add("! 无法确认磁贴是否在控制中心（状态未知）");
        } else {
            String painted = get("painted");
            if (painted == null || "unknown".equals(painted)) {
                out.add("! 磁贴显示状态未知，暂时无法核对");
            } else if (painted.isEmpty() || "null".equals(painted)) {
                out.add("! 磁贴还没画出状态");
                out.add("　展开一次控制中心让它刷新");
            } else if (painted.startsWith("处理中")) {
                out.add("· 磁贴正在刷新，属正常");
            } else if ("需要 root".equals(painted)) {
                out.add("✗ 磁贴显示「需要 root」");
                out.add("　以本次授权检查为准，展开控制中心让它刷新");
            } else if ("模块未安装".equals(painted)) {
                out.add("✗ 磁贴显示「模块未安装」");
            } else if (!"运行中".equals(painted) && !"已停止".equals(painted)) {
                out.add("! 磁贴显示「" + painted + "」，暂时无法核对");
                out.add("　展开控制中心刷新；若仍异常请检查服务日志");
            } else if (!serviceKnown) {
                out.add("· 磁贴显示「" + painted + "」；服务状态未知，暂时无法核对");
            } else {
                String expect = "running".equals(svc) ? "运行中" : "已停止";
                if (painted.equals(expect)) {
                    out.add("✓ 磁贴显示「" + painted + "」，和实际一致");
                } else {
                    out.add("! 磁贴显示「" + painted + "」，实际是「" + expect + "」");
                    out.add("　命令行或看门狗启停过服务，磁贴还没重读");
                    out.add("　展开一次控制中心就会对齐");
                }
            }
        }

        int alive = num(get("alive"));
        int frozen = num(get("frozen"));
        if (alive < 0 || frozen < 0 || frozen > alive) {
            out.add("! 磁贴进程/冻结状态未知（字段缺失、无效或计数矛盾）");
        } else if (alive == 0) {
            out.add("✓ 磁贴进程没在跑，展开时才拉起");
        } else if (frozen == 0) {
            out.add("✓ 磁贴进程没被冻结");
        } else {
            out.add("! 磁贴进程被冻结了，显示会停在上一帧");
            out.add("　" + freezerHint(get("freezer")));
        }
        return out;
    }

    private static String freezerHint(String who) {
        String name;
        if ("NoActive".equals(who)) {
            name = "NoActive";
        } else if ("CZero".equals(who)) {
            name = "CZero";
        } else if ("system".equals(who)) {
            name = "系统的空闲冻结";
        } else if ("greezer".equals(who)) {
            name = "HyperOS 的 greezer";
        } else {
            return "把本 App 加进冻结类模块的白名单";
        }
        return "疑似 " + name + " 在冻。把本 App 加进它的白名单";
    }

    /** 非负十进制计数；缺失、负数、溢出等都不能默认为 0。 */
    private static int num(String s) {
        if (s == null || !s.matches("[0-9]+")) return -1;
        try {
            return Integer.parseInt(s);
        } catch (NumberFormatException e) {
            return -1;
        }
    }
}
