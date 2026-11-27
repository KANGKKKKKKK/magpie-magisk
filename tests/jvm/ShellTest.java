package com.ruin.magpie.tile;

import android.os.Handler;
import android.os.Looper;

/** Shell 的真实进程回归：并发排空、上限、超时与退出码。 */
public final class ShellTest {
    private static int passed;
    private static int failed;

    private static void check(String name, boolean condition, String detail) {
        if (condition) passed++; else failed++;
        System.out.println((condition ? "  PASS  " : "  FAIL  ") + name + (condition ? "" : ": " + detail));
    }

    public static void main(String[] args) {
        // 超过 64 KiB 的 stderr 与 stdout 必须同时读完，不能管道互锁。
        Shell.Result both = Shell.execOnce("sh", "i=0; while [ $i -lt 9000 ]; do printf xxxxxxxx; printf yyyyyyyy >&2; i=$((i+1)); done", 5000L);
        check("并发消费 stdout/stderr", both.ok && both.out.contains("x")
                && both.err.contains("y"), both.err);
        check("stdout 有输出上限", both.out.length() < 70000
                && both.out.contains("output truncated"), String.valueOf(both.out.length()));
        check("stderr 有输出上限", both.err.length() < 70000
                && both.err.contains("output truncated"), String.valueOf(both.err.length()));

        long start = System.nanoTime();
        Shell.Result timeout = Shell.execOnce("sh", "sleep 30", 200L);
        long elapsedMs = (System.nanoTime() - start) / 1000000L;
        check("超时失败", !timeout.ok && timeout.err.contains("timed out"), timeout.err);
        check("超时及时清理进程", elapsedMs < 5000L, elapsedMs + "ms");

        Shell.Result nonzero = Shell.execOnce("sh", "printf problem >&2; exit 7", 1000L);
        check("保留非零退出与 stderr", !nonzero.ok && nonzero.err.contains("problem"), nonzero.err);
        for (String url : new String[]{"http://127.0.0.1:3430/", "http://127.23.0.1:65535/", "http://[::1]:3430/"}) {
            check("接受控制器确认的回环地址 " + url,
                    url.equals(Shell.verifiedPanelUrl(new Shell.Result(true, url, ""))), "unexpected rejection");
        }
        for (String url : new String[]{"http://127.0.0.1:65536/", "http://127.0.0.999:3430/",
                "http://127.00.0.1:3430/", "http://localhost:3430/", "http://127.0.0.1:3430/?test=1",
                "http://[::1]:3430/\nextra output"}) {
            check("拒绝非规范或含额外内容的面板地址",
                    Shell.verifiedPanelUrl(new Shell.Result(true, url, "")) == null, url);
        }
        check("控制器失败时不使用其输出地址",
                Shell.verifiedPanelUrl(new Shell.Result(false, "http://127.0.0.1:3430/", "unavailable")) == null, "accepted failure");
        System.out.println("ShellTest: PASS " + passed + ", FAIL " + failed);
        if (failed != 0) System.exit(1);
    }
}
