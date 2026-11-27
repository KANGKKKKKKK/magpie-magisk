#!/usr/bin/env python3
"""Offline lifecycle regressions compiling the actual production tile service.

Only Android APIs and Shell are in-memory stubs: MagpieTileService.java and
TileState.java are passed directly to javac, not reimplemented or extracted.
Each scenario runs in its own JVM at SDK 29 and 35, with deterministic queued
Shell callbacks and Handler retries. No Android device, su, service commands,
network, credentials, or repository build artifacts are used.

Run: python3 tests/test-tile-lifecycle.py
Requires Python 3 plus javac/java; all generated files live in a temporary dir.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tile-app/src/com/ruin/magpie/tile"

STUBS = {
    "android/content/Context.java": r'''
package android.content;
public class Context {
    public String getString(int id) { return "resource-" + id; }
}
''',
    "android/content/ComponentName.java": r'''
package android.content;
public class ComponentName {
    public ComponentName(Context context, Class<?> type) {}
}
''',
    "android/graphics/drawable/Icon.java": r'''
package android.graphics.drawable;
import android.content.Context;
public class Icon {
    public static Icon createWithResource(Context context, int resource) {
        return new Icon();
    }
}
''',
    "android/os/Build.java": r'''
package android.os;
public class Build {
    public static class VERSION { public static int SDK_INT = 35; }
    public static class VERSION_CODES { public static final int Q = 29, R = 30; }
}
''',
    "android/os/Looper.java": r'''
package android.os;
public class Looper {
    public static Looper getMainLooper() { return new Looper(); }
}
''',
    "android/os/Handler.java": r'''
package android.os;
import java.util.ArrayDeque;
public class Handler {
    private static final ArrayDeque<Runnable> QUEUE = new ArrayDeque<>();
    public Handler(Looper looper) {}
    public boolean postDelayed(Runnable task, long delay) {
        QUEUE.add(task);
        return true;
    }
    public static int pending() { return QUEUE.size(); }
    public static void drain() {
        int remaining = 100;
        while (!QUEUE.isEmpty()) {
            if (--remaining == 0) throw new AssertionError("retry queue did not settle");
            QUEUE.remove().run();
        }
    }
}
''',
    "android/os/SystemClock.java": r'''
package android.os;
public class SystemClock {
    public static long now = 10000L;
    public static long elapsedRealtime() { return now; }
}
''',
    "android/service/quicksettings/Tile.java": r'''
package android.service.quicksettings;
import android.graphics.drawable.Icon;
public class Tile {
    public static final int STATE_UNAVAILABLE = 0, STATE_INACTIVE = 1, STATE_ACTIVE = 2;
    public int state = -1;
    public int updates;
    public String subtitle = "";
    public void setLabel(String label) {}
    public void setSubtitle(String value) { subtitle = value; }
    public void setStateDescription(String value) {}
    public void setIcon(Icon icon) {}
    public void setState(int value) { state = value; }
    public void updateTile() { ++updates; }
}
''',
    "android/service/quicksettings/TileService.java": r'''
package android.service.quicksettings;
import android.content.ComponentName;
import android.content.Context;
import java.util.ArrayDeque;
public class TileService extends Context {
    public final Tile tile = new Tile();
    public boolean tileAvailable = true;
    public boolean deferUnlock;
    public boolean stoppedSelf;
    private final ArrayDeque<Runnable> unlocks = new ArrayDeque<>();
    public void onStartListening() {}
    public void onStopListening() {}
    public void onDestroy() {}
    public void onTileRemoved() {}
    public void onClick() {}
    public Tile getQsTile() { return tileAvailable ? tile : null; }
    public void unlockAndRun(Runnable task) {
        if (deferUnlock) unlocks.add(task); else task.run();
    }
    public void finishUnlocks() {
        while (!unlocks.isEmpty()) unlocks.remove().run();
    }
    public void stopSelf() { stoppedSelf = true; }
    public static void requestListeningState(Context context, ComponentName component) {}
}
''',
    "com/ruin/magpie/tile/R.java": r'''
package com.ruin.magpie.tile;
final class R {
    static final class string {
        static final int tile_label = 1, state_running = 2, state_stopped = 3,
            state_no_root = 4, state_failed = 5, state_unavailable = 6,
            state_unknown = 7, state_working = 8;
    }
    static final class drawable { static final int ic_tile = 1; }
}
''',
    "com/ruin/magpie/tile/Shell.java": r'''
package com.ruin.magpie.tile;
import java.util.ArrayList;
import java.util.List;
final class Shell {
    interface Callback<T> { void onResult(T result); }
    static final class Result {
        final boolean ok;
        final String out, err;
        Result(String state) { this(true, state, ""); }
        Result(boolean success, String state, String error) { ok = success; out = state; err = error; }
    }
    private static final class Pending {
        final String command;
        final Callback<Result> callback;
        boolean completed;
        Pending(String value, Callback<Result> result) { command = value; callback = result; }
    }
    private static final List<Pending> REQUESTS = new ArrayList<>();
    static String statusCommand() { return "in-memory-status"; }
    static String toggleIfCommand(String state) { return "in-memory-toggle-if " + state; }
    static boolean toggles(String command) {
        return command.equals(toggleIfCommand("running")) || command.equals(toggleIfCommand("stopped"));
    }
    static void run(String command, Callback<Result> callback) {
        if (!command.equals(statusCommand()) && !toggles(command)) {
            throw new AssertionError("unexpected command: " + command);
        }
        REQUESTS.add(new Pending(command, callback));
    }
    static int count(String command) {
        int count = 0;
        for (Pending request : REQUESTS) if (request.command.equals(command)) ++count;
        return count;
    }
    static void complete(String command, String state) { complete(command, new Result(state)); }
    static void complete(String command, Result result) {
        for (Pending request : REQUESTS) {
            if (!request.completed && (request.command.equals(command) || (command.equals("toggle") && toggles(request.command)))) {
                request.completed = true;
                request.callback.onResult(result);
                return;
            }
        }
        throw new AssertionError("no pending " + command);
    }
    static void repeatFirst(String state) {
        REQUESTS.get(0).callback.onResult(new Result(state));
    }
}
''',
}

HARNESS = r'''
package com.ruin.magpie.tile;

import android.os.Build;
import android.os.Handler;
import android.os.SystemClock;
import android.service.quicksettings.Tile;

public final class TileLifecycleHarness {
    private static int assertions;
    private static void check(boolean condition, String message) {
        ++assertions;
        if (!condition) throw new AssertionError(message);
    }
    private static MagpieTileService listening() {
        MagpieTileService service = new MagpieTileService();
        service.onStartListening();
        return service;
    }
    private static void expect(MagpieTileService service, String state) {
        int resource, tileState;
        switch (state) {
            case "running": resource = R.string.state_running; tileState = Tile.STATE_ACTIVE; break;
            case "stopped": resource = R.string.state_stopped; tileState = Tile.STATE_INACTIVE; break;
            default: resource = R.string.state_working; tileState = Tile.STATE_UNAVAILABLE;
        }
        check(service.tile.state == tileState, state + ": wrong tile state " + service.tile.state);
        check(service.tile.subtitle.equals(service.getString(resource)), state + ": wrong subtitle");
    }
    private static void counts(int reads, int toggles) {
        check(Shell.count(Shell.statusCommand()) == reads, "duplicate or missing status read");
        check(Shell.count(Shell.toggleIfCommand("running")) + Shell.count(Shell.toggleIfCommand("stopped")) == toggles,
                "duplicate or missing conditional toggle");
    }
    private static void finishRead(String state) { Shell.complete(Shell.statusCommand(), state); }
    private static void finishToggle(String state) { Shell.complete("toggle", state); }
    private static MagpieTileService running() {
        MagpieTileService service = listening();
        finishRead("running");
        expect(service, "running");
        return service;
    }

    public static void main(String[] args) {
        Build.VERSION.SDK_INT = Integer.parseInt(args[1]);
        switch (args[0]) {
            case "read_recreated": {
                MagpieTileService old = listening();
                old.onDestroy();
                int updates = old.tile.updates;
                MagpieTileService current = listening();
                current.onStartListening();
                counts(1, 0);
                finishRead("running");
                expect(current, "running");
                check(old.tile.updates == updates, "destroyed instance repainted on read completion");
                int currentUpdates = current.tile.updates;
                Shell.repeatFirst("stopped");
                check(current.tile.updates == currentUpdates, "duplicate read completion repainted");
                counts(1, 0);
                break;
            }
            case "read_rebound": {
                MagpieTileService old = listening();
                MagpieTileService current = listening();
                old.onStopListening();
                old.onDestroy();
                finishRead("running");
                expect(current, "running");
                check(old.tile.updates == 1, "old instance repainted after rebind");
                counts(1, 0);
                break;
            }
            case "toggle_recreated": {
                MagpieTileService old = running();
                old.onClick();
                expect(old, "working");
                old.onDestroy();
                int updates = old.tile.updates;
                MagpieTileService current = listening();
                expect(current, "working");
                current.onStartListening();
                current.onClick();
                current.onClick();
                counts(1, 1);
                finishToggle("stopped");
                expect(current, "stopped");
                check(old.tile.updates == updates, "destroyed instance repainted on toggle completion");
                current.onClick();
                counts(1, 2);
                finishToggle("running");
                expect(current, "running");
                break;
            }
            case "toggle_rebound": {
                MagpieTileService old = running();
                old.onClick();
                MagpieTileService current = listening();
                old.onStopListening();
                old.onDestroy();
                current.onClick();
                counts(1, 1);
                finishToggle("stopped");
                expect(current, "stopped");
                check(old.tile.updates == 3, "old instance repainted after toggle rebind");
                break;
            }
            case "read_closed": {
                MagpieTileService service = listening();
                service.tileAvailable = false;
                service.onStartListening();
                check(Handler.pending() > 0, "read did not queue retry before closing");
                service.onStopListening();
                int updates = service.tile.updates;
                finishRead("running");
                service.tileAvailable = true;
                Handler.drain();
                check(service.tile.updates == updates, "closed instance rendered read completion");
                service.onStartListening();
                expect(service, "running");
                counts(1, 0);
                break;
            }
            case "toggle_closed": {
                MagpieTileService service = running();
                service.tileAvailable = false;
                service.onClick();
                check(Handler.pending() > 0, "toggle did not queue retry before closing");
                service.onStopListening();
                int updates = service.tile.updates;
                finishToggle("stopped");
                service.tileAvailable = true;
                Handler.drain();
                check(service.tile.updates == updates, "closed instance rendered toggle completion");
                service.onStartListening();
                expect(service, "stopped");
                counts(1, 1);
                service.onClick();
                counts(1, 2);
                finishToggle("running");
                expect(service, "running");
                break;
            }
            case "read_finishes_without_instance": {
                MagpieTileService old = listening();
                old.onDestroy();
                int updates = old.tile.updates;
                finishRead("running");
                Handler.drain();
                check(old.tile.updates == updates, "destroyed instance rendered unobserved read");
                MagpieTileService current = listening();
                expect(current, "running");
                counts(1, 0);
                break;
            }
            case "toggle_finishes_without_instance": {
                MagpieTileService old = running();
                old.onClick();
                old.onDestroy();
                int updates = old.tile.updates;
                finishToggle("stopped");
                Handler.drain();
                check(old.tile.updates == updates, "destroyed instance rendered unobserved toggle");
                MagpieTileService current = listening();
                expect(current, "stopped");
                counts(1, 1);
                current.onClick();
                counts(1, 2);
                finishToggle("running");
                expect(current, "running");
                break;
            }
            case "old_lifecycle_preserves_current_retry": {
                MagpieTileService old = listening();
                MagpieTileService current = new MagpieTileService();
                current.tileAvailable = false;
                current.onStartListening();
                finishRead("running");
                check(Handler.pending() > 0, "current instance did not queue render retry");
                old.onStopListening();
                old.onDestroy();
                current.tileAvailable = true;
                Handler.drain();
                expect(current, "running");
                check(current.tile.updates == 1, "obsolete working retry repainted current tile");
                check(old.tile.updates == 1, "old instance repainted during current retry");
                counts(1, 0);
                break;
            }
            case "old_retry_cannot_repaint": {
                MagpieTileService old = new MagpieTileService();
                old.tileAvailable = false;
                old.onStartListening();
                check(Handler.pending() > 0, "old instance did not queue retry");
                MagpieTileService current = listening();
                finishRead("running");
                int updates = current.tile.updates;
                old.tileAvailable = true;
                Handler.drain();
                check(old.tile.updates == 0, "replaced instance rendered obsolete retry");
                check(current.tile.updates == updates, "old retry disturbed current rendering");
                expect(current, "running");
                counts(1, 0);
                break;
            }
            case "old_read_during_toggle": {
                MagpieTileService old = listening();
                MagpieTileService current = listening();
                current.onClick();
                counts(1, 0);
                old.onDestroy();
                finishRead("running");
                expect(current, "running");
                current.onClick();
                counts(1, 1);
                Shell.repeatFirst("running");
                expect(current, "working");
                finishToggle("stopped");
                expect(current, "stopped");
                counts(1, 1);
                break;
            }
            case "stale_unlock_after_destroy": {
                MagpieTileService old = listening();
                old.deferUnlock = true;
                old.onClick();
                old.onDestroy();
                MagpieTileService current = listening();
                old.finishUnlocks();
                counts(1, 0);
                finishRead("running");
                expect(current, "running");
                break;
            }
            case "stale_unlock_after_rebind": {
                MagpieTileService old = listening();
                old.deferUnlock = true;
                old.onClick();
                MagpieTileService current = listening();
                old.finishUnlocks();
                counts(1, 0);
                finishRead("running");
                expect(current, "running");
                break;
            }
            case "tile_removed_keeps_busy": {
                MagpieTileService old = running();
                old.onClick();
                old.onTileRemoved();
                check(old.stoppedSelf, "removed service did not stop itself");
                int updates = old.tile.updates;
                MagpieTileService current = listening();
                expect(current, "working");
                current.onClick();
                counts(1, 1);
                finishToggle("stopped");
                expect(current, "stopped");
                check(old.tile.updates == updates, "removed instance rendered completion");
                break;
            }
            case "different_state_only_refreshes": {
                MagpieTileService service = running();
                service.onClick();
                check(Shell.count(Shell.toggleIfCommand("running")) == 1, "painted running was not sent");
                Shell.complete("toggle", new Shell.Result(false, "stale stopped", ""));
                counts(2, 1);
                finishRead("stopped");
                expect(service, "stopped");
                service.onClick();
                check(Shell.count(Shell.toggleIfCommand("stopped")) == 1, "painted stopped was not sent");
                Shell.complete("toggle", new Shell.Result(false, "usage: old controller", ""));
                counts(3, 2);
                finishRead("stopped");
                break;
            }
            case "expired_cache_does_not_control": {
                MagpieTileService service = running();
                SystemClock.now += 5001L;
                service.onClick();
                counts(2, 0);
                finishRead("stopped");
                expect(service, "stopped");
                break;
            }
            case "timed_out_action_never_replays": {
                MagpieTileService service = running();
                service.onClick();
                Shell.complete("toggle", new Shell.Result(false, "running", "timed out"));
                counts(2, 1);
                finishRead("running");
                expect(service, "running");
                counts(2, 1);
                break;
            }
            case "old_unlock_same_instance": {
                MagpieTileService service = running();
                service.deferUnlock = true;
                service.onClick();
                service.onStopListening();
                service.onStartListening();
                service.finishUnlocks();
                counts(1, 0);
                expect(service, "running");
                break;
            }
            default: throw new AssertionError("unknown scenario " + args[0]);
        }
        System.out.println("PASS " + args[0] + " sdk=" + args[1] + " assertions=" + assertions);
    }
}
'''


class TileLifecycleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ("javac", "java"):
            if shutil.which(tool) is None:
                raise RuntimeError("Lifecycle tests require " + tool + "; refusing to skip")
        cls.tmp = tempfile.TemporaryDirectory(prefix="magpie-tile-lifecycle-")
        cls.addClassCleanup(cls.tmp.cleanup)
        work = Path(cls.tmp.name)
        sources = [SOURCE / "MagpieTileService.java", SOURCE / "TileState.java"]
        for relative, body in STUBS.items():
            path = work / "src" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
            sources.append(path)
        harness = work / "src/com/ruin/magpie/tile/TileLifecycleHarness.java"
        harness.write_text(HARNESS, encoding="utf-8")
        sources.append(harness)
        cls.classes = work / "classes"
        cls.classes.mkdir()
        result = subprocess.run(
            ["javac", "-encoding", "UTF-8", "-d", str(cls.classes),
             *map(str, sources)], capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError("Production lifecycle compilation failed:\n" + result.stdout + result.stderr)

    def run_scenario(self, name):
        for sdk in (29, 35):
            with self.subTest(sdk=sdk):
                result = subprocess.run(
                    ["java", "-cp", str(self.classes),
                     "com.ruin.magpie.tile.TileLifecycleHarness", name, str(sdk)],
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS " + name + " sdk=" + str(sdk), result.stdout)

    def test_read_recreated_before_completion(self):
        self.run_scenario("read_recreated")

    def test_read_rebound_before_old_destroy(self):
        self.run_scenario("read_rebound")

    def test_toggle_recreated_before_completion(self):
        self.run_scenario("toggle_recreated")

    def test_toggle_rebound_before_old_destroy(self):
        self.run_scenario("toggle_rebound")

    def test_read_while_closed_only_updates_cache(self):
        self.run_scenario("read_closed")

    def test_toggle_while_closed_releases_busy_without_render(self):
        self.run_scenario("toggle_closed")

    def test_read_finishes_between_instances(self):
        self.run_scenario("read_finishes_without_instance")

    def test_toggle_finishes_between_instances(self):
        self.run_scenario("toggle_finishes_without_instance")

    def test_old_lifecycle_does_not_invalidate_current_retry(self):
        self.run_scenario("old_lifecycle_preserves_current_retry")

    def test_old_delayed_retry_cannot_repaint_replacement(self):
        self.run_scenario("old_retry_cannot_repaint")

    def test_old_read_cannot_release_toggle_busy_after_rebind(self):
        self.run_scenario("old_read_during_toggle")

    def test_deferred_unlock_from_destroyed_instance_is_ignored(self):
        self.run_scenario("stale_unlock_after_destroy")

    def test_deferred_unlock_from_replaced_instance_is_ignored(self):
        self.run_scenario("stale_unlock_after_rebind")

    def test_removal_preserves_inflight_toggle_busy(self):
        self.run_scenario("tile_removed_keeps_busy")

    def test_different_state_and_old_controller_only_refresh(self):
        self.run_scenario("different_state_only_refreshes")

    def test_expired_cached_paint_refreshes_without_control(self):
        self.run_scenario("expired_cache_does_not_control")

    def test_ambiguous_timeout_never_replays(self):
        self.run_scenario("timed_out_action_never_replays")

    def test_deferred_unlock_from_previous_epoch_is_ignored(self):
        self.run_scenario("old_unlock_same_instance")


if __name__ == "__main__":
    unittest.main(verbosity=2)
