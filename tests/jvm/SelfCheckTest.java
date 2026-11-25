package com.ruin.magpie.tile;

/*
 * SelfCheck 的判定逻辑（JVM 单测，不需要 Android 设备）。
 *
 * 为什么要测：自查结果决定用户看到「✓ 一切正常」还是「! 被冻结了」。
 * 判错的后果比不显示更糟——用户会照着错误的提示去改别的地方。
 *
 *   javac -encoding UTF-8 tile-app/src/com/ruin/magpie/tile/SelfCheck.java \
 *         tests/jvm/SelfCheckTest.java -d /tmp/cls
 *   java -cp /tmp/cls com.ruin.magpie.tile.SelfCheckTest
 *
 * 退出码非 0 表示有用例失败。
 */
public class SelfCheckTest {

    private static int failed = 0;

    /** 断言输出里存在某条（用 contains，文案可以微调）。 */
    private static void has(String name, String out, String expect) {
        boolean pass = out.contains(expect);
        if (!pass) {
            failed++;
        }
        System.out.printf("  %-6s %-28s %s%s%n",
                pass ? "PASS" : "FAIL", name,
                pass ? "含「" + expect + "」" : "缺少「" + expect + "」，实际：",
                pass ? "" : "\n" + out);
    }

    /** 断言输出里不存在某条。 */
    private static void not(String name, String out, String expect) {
        boolean pass = !out.contains(expect);
        if (!pass) {
            failed++;
        }
        System.out.printf("  %-6s %-28s %s%n",
                pass ? "PASS" : "FAIL", name, pass ? "不含「" + expect + "」" : "不该出现「" + expect + "」");
    }

    private static String run(String raw) {
        StringBuilder sb = new StringBuilder();
        for (String line : SelfCheck.parse(raw).report()) {
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(line);
        }
        return sb.toString();
    }

    public static void main(String[] a) {
        // ---- 拿不到 root：su 失败时 out 为空 ----
        String r = run(null);
        has("空输出-报没root", r, "拿不到 root 权限");
        not("空输出-不提冻结", r, "冻结");

        // ---- 模块不在 ----
        has("模块不在", run("mod=0"), "没找到 magpie 模块");

        // ---- 模块是旧版（没有 tile-check.sh） ----
        has("旧版模块", run("mod=1\nold=1"), "模块是旧版");

        // ---- 一切正常 ----
        r = run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nvcode=9\n"
                + "magisk=2\ninqs=1\npainted=运行中\nalive=0\nfrozen=0\nfreezer=NoActive");
        has("正常-服务在跑", r, "Magpie 服务正在运行");
        has("正常-root已授权", r, "root 已授权");
        has("正常-显示一致", r, "和实际一致");
        has("正常-进程未运行", r, "展开时才拉起");
        not("正常-无警告", r, "被冻结");

        // ---- 服务停了，磁贴还显示运行中 ----
        r = run("mod=1\nsvc=stopped\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                + "painted=运行中\nalive=0\nfrozen=0");
        has("不一致-提示实际已停止", r, "实际是「已停止」");
        has("不一致-说明原因", r, "磁贴还没重读");

        // ---- 服务停了，磁贴也显示已停止 ----
        r = run("mod=1\nsvc=stopped\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                + "painted=已停止\nalive=0\nfrozen=0");
        has("一致-已停止", r, "和实际一致");

        // ---- root 被拒 ----
        r = run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=1\ninqs=1\n"
                + "painted=运行中\nalive=0\nfrozen=0");
        has("root被拒", r, "root 被拒绝了");
        has("root被拒-给路径", r, "超级用户");

        // ---- root 未授权 ----
        has("root未授权",
                run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=0\ninqs=1\n"
                        + "painted=需要 root\nalive=0\nfrozen=0"),
                "root 还没授权");

        // ---- 非 Magisk 环境：magisk=absent，不该报 root 相关 ----
        r = run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=absent\ninqs=1\n"
                + "painted=运行中\nalive=0\nfrozen=0");
        not("非Magisk-不提root", r, "root");

        // ---- 不在控制中心 ----
        r = run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=0\n"
                + "painted=\nalive=0\nfrozen=0");
        has("不在面板", r, "磁贴不在控制中心");
        not("不在面板-不谈绘制", r, "运行中");

        // ---- 还没画出状态 ----
        has("未绘制",
                run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                        + "painted=null\nalive=0\nfrozen=0"),
                "磁贴还没画出状态");

        // ---- 处理中是瞬态，不算问题 ----
        r = run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                + "painted=处理中…\nalive=1\nfrozen=0");
        has("处理中-正常", r, "正在刷新");

        // ---- 被冻结（NoActive） ----
        r = run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                + "painted=运行中\nalive=1\nfrozen=1\nfreezer=NoActive");
        has("冻结-报出来", r, "磁贴进程被冻结");
        has("冻结-指出NoActive", r, "NoActive");
        has("冻结-给办法", r, "白名单");

        // ---- 被冻结（系统空闲冻结） ----
        has("冻结-system",
                run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                        + "painted=运行中\nalive=2\nfrozen=1\nfreezer=system"),
                "系统的空闲冻结");

        // ---- 被冻结但认不出是谁：仍要给出办法 ----
        r = run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                + "painted=运行中\nalive=1\nfrozen=1\nfreezer=");
        has("冻结-未知来源", r, "加进冻结类模块的白名单");
        not("冻结-未知不瞎猜", r, "疑似");

        // ---- 磁贴显示模块未安装 ----
        has("显示模块未安装",
                run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                        + "painted=模块未安装\nalive=0\nfrozen=0"),
                "磁贴显示「模块未安装」");

        // ---- 有进程但没冻 ----
        has("进程未冻结",
                run("mod=1\nsvc=running\ninstalled=1\nuid=10330\nmagisk=2\ninqs=1\n"
                        + "painted=运行中\nalive=1\nfrozen=0"),
                "磁贴进程没被冻结");

        if (failed > 0) {
            System.out.println("\n" + failed + " 个用例失败");
            System.exit(1);
        }
        System.out.println("\n全部通过");
    }
}
