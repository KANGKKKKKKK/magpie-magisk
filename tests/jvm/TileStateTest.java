package com.ruin.magpie.tile;

/** Deterministic request-completion ordering: no sleeps, Android, or root. */
public final class TileStateTest {
    private static int passed;
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
        passed++;
        System.out.println("  PASS  " + message);
    }
    public static void main(String[] args) {
        TileState s = new TileState();
        check(s.lastState() == null, "new state is unknown, not stopped");
        check(s.freshState(100L, 5000L) == null, "empty cache is not fresh");
        long old = s.beginRead();
        check(old != -1L, "first read begins");
        check(s.beginRead() == -1L, "duplicate status reads coalesce");
        long action = s.beginToggle();
        check(action != -1L && s.isBusy(), "toggle starts and marks busy");
        check(s.beginToggle() == -1L, "queued duplicate click cannot toggle twice");
        check(s.beginRead() == -1L, "listening during toggle cannot query stale state");
        check(!s.completeRead(old, "running", 100L), "old read cannot release busy or repaint working");
        check(s.isBusy(), "old read cannot release action busy guard");
        check(s.completeToggle(action, "stopped", 200L), "newer stop result accepted");
        check(!s.completeRead(old, "running", 210L), "late pre-toggle status rejected");
        check("stopped".equals(s.lastState()), "late running result cannot overwrite stopped");
        check(!s.isBusy(), "action completion releases busy");
        check(!s.completeToggle(action, "running", 220L), "duplicate action result ignored");
        check("stopped".equals(s.freshState(300L, 5000L)), "cache fresh within five seconds");
        check(s.freshState(5200L, 5000L) == null, "cache expires exactly at max age");
        check(s.freshState(100L, 5000L) == null, "negative clock delta not treated as fresh");
        long read = s.beginRead();
        s.invalidateCache();
        check(!s.completeRead(read, "running", 6000L), "explicit refresh invalidates pending read");
        check(s.lastState() == null, "explicit refresh clears cache");
        long refreshed = s.beginRead();
        check(refreshed != -1L, "read can restart after invalidation");
        check(s.completeRead(refreshed, "running", 6100L), "fresh read accepted");
        long nextAction = s.beginToggle();
        s.invalidateCache();
        check(s.isBusy(), "external refresh cannot release active operation");
        check(s.beginToggle() == -1L, "external refresh cannot enable duplicate action");
        check(s.completeToggle(nextAction, "unknown", 6200L), "action can finish after external refresh");
        check("unknown".equals(s.lastState()), "failed/uncertain result never inherits old running state");
        check(!s.completeRead(-1L, "running", 6300L), "invalid read token ignored");
        check(!s.completeToggle(-1L, "running", 6300L), "invalid action token ignored");
        long newer = s.beginRead();
        check(s.completeRead(newer, "stopped", 6400L), "subsequent valid status recovers unknown");
        System.out.println("TileStateTest: PASS " + passed);
    }
}
