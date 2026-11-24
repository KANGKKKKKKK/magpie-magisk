/*
 * MagpieTileService.classify 的判定逻辑（JVM 单测，不需要 Android 设备）。
 *
 * 为什么要单独测：这段逻辑决定磁贴显示什么。判错的后果是「启动失败」被画成
 * 「已停止」或「需要 root」，用户看到的提示与实际原因完全对不上。
 *
 *   javac tests/jvm/ClassifyTest.java -d /tmp/cls && java -cp /tmp/cls ClassifyTest
 *
 * 退出码非 0 表示有用例失败。
 */
public class ClassifyTest {
    static final String NO_MODULE = "__magpie_nomodule__";

    static String classify(boolean ok, String raw, String fallback) {
        String out = raw == null ? "" : raw.trim();
        if (out.contains(NO_MODULE)) return "nomodule";
        String last = out;
        int nl = out.lastIndexOf('\n');
        if (nl >= 0) last = out.substring(nl + 1).trim();
        if (last.equals("running") || last.startsWith("running ")) return "running";
        if (last.equals("stopped") || last.startsWith("stopped ")) return "stopped";
        if (last.equals("failed")  || last.startsWith("failed "))  return "failed";
        if (out.isEmpty() && !ok) return "noroot";
        return fallback;
    }
    static void t(boolean ok, String out, String expect) {
        String got = classify(ok, out, "stopped");
        boolean pass = got.equals(expect);
        if (!pass) failed++;
        System.out.printf("  %-6s ok=%-5s %-26s → %-8s %s%n",
            pass ? "PASS" : "FAIL", ok, "'" + out.replace("\n", "\\n") + "'", got,
            pass ? "" : "(期望 " + expect + ")");
    }
    private static int failed = 0;

    public static void main(String[] a) {
        t(true,  "running (PID 123)", "running");
        t(true,  "running",            "running");
        t(true,  "stopped",            "stopped");
        t(true,  "failed",             "failed");
        t(false, "failed",             "failed");
        t(false, "",                   "noroot");
        t(false, "sh: xxx: not found", "stopped");
        t(true,  "",                   "stopped");
        t(true,  "2026-11-24 12:00:00 [Warn] 正在停止\nrunning", "running");
        t(true,  "running\r\n",        "running");
        // 模块被删：su 跑得通，但脚本不存在 → 命令打印哨兵
        t(true,  NO_MODULE,            "nomodule");
        t(false, NO_MODULE,            "nomodule");
        // 哨兵混在其它输出里也要认出来
        t(true,  "something\n" + NO_MODULE, "nomodule");
        System.out.println();
        System.out.println("结果： FAIL " + failed);
        if (failed > 0) System.exit(1);
    }
}
