package com.ruin.magpie.tile;

/** Pure state/ordering logic shared by the tile and host-side regression tests. */
final class TileState {
    private long generation;
    private long pendingRead = -1L;
    private boolean busy;
    private String cached;
    private long cachedAt;

    static String classify(boolean ok, String raw, String error) {
        String out = raw == null ? "" : raw.trim();
        String err = error == null ? "" : error;
        // A timed-out/truncated command has no trustworthy final result, even if
        // its partial output happens to end with a recognizable word.
        if (err.contains("timed out") || err.contains("[output truncated]")
                || out.contains("[output truncated]")) return "unknown";
        if (out.contains("__magpie_nomodule__")) return "nomodule";
        int nl = out.lastIndexOf('\n');
        String last = nl < 0 ? out : out.substring(nl + 1).trim();
        if (last.equals("failed") || last.startsWith("failed ")) return "failed";
        if (last.equals("running") || last.startsWith("running ")) return ok ? "running" : "unknown";
        // A start cancelled by a newer stop deliberately exits 2 with 'stopped'.
        if (last.equals("stopped") || last.startsWith("stopped ")) return "stopped";
        if (out.isEmpty() && !ok && "no su".equals(err.trim())) return "noroot";
        return "unknown";
    }

    boolean isBusy() { return busy; }
    String lastState() { return cached; }

    String freshState(long now, long maxAge) {
        long age = now - cachedAt;
        return cached != null && age >= 0L && age < maxAge ? cached : null;
    }

    long beginRead() {
        if (busy || pendingRead != -1L) return -1L;
        pendingRead = ++generation;
        return pendingRead;
    }

    boolean completeRead(long token, String state, long now) {
        if (busy || token == -1L || token != pendingRead || token != generation) return false;
        pendingRead = -1L;
        cache(state, now);
        return true;
    }

    long beginToggle() {
        if (busy) return -1L;
        busy = true;
        pendingRead = -1L;
        return ++generation; // Invalidates every read started before this action.
    }

    boolean completeToggle(long token, String state, long now) {
        if (!busy || token == -1L || token != generation) return false;
        busy = false;
        cache(state, now);
        return true;
    }

    void invalidateCache() {
        cached = null;
        cachedAt = 0L;
        // An external refresh must not cancel a real action or release its busy
        // guard before the command has returned. Its result will refresh cache.
        if (!busy) {
            ++generation;
            pendingRead = -1L;
        }
    }

    private void cache(String state, long now) {
        cached = state;
        cachedAt = now;
    }
}
