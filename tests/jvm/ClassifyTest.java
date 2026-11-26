package com.ruin.magpie.tile;

/** Calls the production classifier, not a copy of its implementation. */
public final class ClassifyTest {
    private static int passed;
    private static int failed;

    private static void t(boolean ok, String out, String err, String expected) {
        String got = TileState.classify(ok, out, err);
        boolean pass = expected.equals(got);
        if (pass) passed++; else failed++;
        System.out.println("  " + (pass ? "PASS" : "FAIL") + " classify "
                + String.valueOf(out).replace("\n", "\\n") + " -> " + got + " (" + expected + ")");
    }

    public static void main(String[] args) {
        t(true, "running (PID 123)", "", "running");
        t(true, "running", "", "running");
        t(true, "stopped", "", "stopped");
        t(true, "failed", "", "failed");
        t(false, "failed", "", "failed");
        t(false, "", "no su", "noroot");
        t(false, "", "permission denied", "unknown");
        t(false, "sh: xxx: not found", "", "unknown");
        t(true, "", "", "unknown");
        t(true, "[Warn] log\nrunning", "", "running");
        t(true, "running\r\n", "", "running");
        t(true, "__magpie_nomodule__", "", "nomodule");
        t(false, "__magpie_nomodule__", "", "nomodule");
        t(true, "log\n__magpie_nomodule__", "", "nomodule");
        t(false, "stopped", "", "stopped");
        t(false, "running", "command timed out", "unknown");
        t(false, "running", "exit 1", "unknown");
        t(false, "stopped", "command timed out", "unknown");
        t(true, "running", "[output truncated]", "unknown");
        t(true, null, null, "unknown");
        t(true, "not running", "", "unknown");
        System.out.println("ClassifyTest: PASS " + passed + ", FAIL " + failed);
        if (failed != 0) throw new AssertionError(failed);
    }
}
