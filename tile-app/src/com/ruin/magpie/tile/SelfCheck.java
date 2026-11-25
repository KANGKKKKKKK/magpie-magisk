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
     * 三种情形分开报：
     * <ul>
     *   <li>脚本在 —— 正常自查</li>
     *   <li>模块在、脚本不在 —— 模块是旧版，得先更新</li>
     *   <li>模块不在 —— 没刷模块</li>
     * </ul>
     * 不分开的话，旧版模块会被报成「没找到模块」，反而误导。
     */
    static String command() {
        return "if [ -f " + SCRIPT + " ]; then sh " + SCRIPT
                + "; elif [ -d " + MODULE_DIR + " ]; then echo mod=1; echo old=1;"
                + " else echo mod=0; fi";
    }

    private final List<String> lines;

    private SelfCheck(List<String> lines) {
        this.lines = lines;
    }

    static SelfCheck parse(String out) {
        List<String> list = new ArrayList<>();
        if (out != null) {
            for (String l : out.split("\n")) {
                String s = l.trim();
                if (!s.isEmpty()) {
                    list.add(s);
                }
            }
        }
        return new SelfCheck(list);
    }

    private String get(String key) {
        for (String l : lines) {
            if (l.startsWith(key + "=")) {
                return l.substring(key.length() + 1).trim();
            }
        }
        return "";
    }

    /** 按「服务 → root → 磁贴显示 → 冻结」的顺序给结论。 */
    List<String> report() {
        List<String> out = new ArrayList<>();
        if (lines.isEmpty()) {
            out.add("✗ 拿不到 root 权限");
            out.add("　自查要读模块目录和 cgroup，没有 root 看不了");
            return out;
        }
        if ("0".equals(get("mod"))) {
            out.add("✗ 没找到 magpie 模块");
            out.add("　磁贴靠模块里的脚本启停，先刷入模块");
            return out;
        }
        if ("1".equals(get("old"))) {
            out.add("! 模块是旧版，没有自查脚本");
            out.add("　更新模块后这里才有用");
            return out;
        }

        String svc = get("svc");
        if ("running".equals(svc)) {
            out.add("✓ Magpie 服务正在运行");
        } else if ("stopped".equals(svc)) {
            out.add("! Magpie 服务没有运行");
            out.add("　点一下磁贴就能启动");
        } else {
            out.add("! 读不到服务状态");
        }

        if (!"1".equals(get("installed"))) {
            out.add("✗ 磁贴 App 不在（这条不该出现，重装试试）");
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
        }

        if ("0".equals(get("inqs"))) {
            out.add("! 磁贴不在控制中心");
            out.add("　在控制中心编辑里把 Magpie 拖出来");
        } else {
            String painted = get("painted");
            if (painted.isEmpty() || "null".equals(painted)) {
                out.add("! 磁贴还没画出状态");
                out.add("　展开一次控制中心让它刷新");
            } else if (painted.startsWith("处理中")) {
                out.add("· 磁贴正在刷新，属正常");
            } else if ("需要 root".equals(painted)) {
                out.add("✗ 磁贴显示「需要 root」");
                out.add("　看上一条 root 授权");
            } else if ("模块未安装".equals(painted)) {
                out.add("✗ 磁贴显示「模块未安装」");
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
        if (alive == 0) {
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

    private static int num(String s) {
        try {
            return Integer.parseInt(s.trim());
        } catch (Exception e) {
            return 0;
        }
    }
}
