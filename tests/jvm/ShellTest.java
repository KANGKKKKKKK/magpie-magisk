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
        System.out.println("ShellTest: PASS " + passed + ", FAIL " + failed);
        if (failed != 0) System.exit(1);
    }
}
