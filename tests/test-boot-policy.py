#!/usr/bin/env python3
"""Boot policy on disposable ordinary files only; no Android, real PM, gateway, or network."""
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


class BootPolicyTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="magpie-boot-policy-")
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        self.adb = self.base / "data/adb"
        self.owned = self.adb / "magpie"
        self.mod = self.base / "module"
        self.scripts = self.mod / "scripts"
        self.scripts.mkdir(parents=True)
        self.stubs = self.base / "stubs"
        self.stubs.mkdir()
        self.conf = self.base / "user.config"
        self.conf.write_text(f'magpie_path="{self.owned}"\n')
        # Relocate literal device paths in copies only; do NOT override the allowlist
        # predicate or introduce a configurable production trust root.
        self.boot_id = self.base / "boot-id"
        self.boot_id.write_text("00000000-0000-0000-0000-000000000001\n")

        def relocated(name):
            return ((ROOT / name).read_text().replace("/data/adb", str(self.adb))
                    .replace("/proc/sys/kernel/random/boot_id", str(self.boot_id)))
        self.lib = self.scripts / "lib.sh"
        self.lib.write_text(relocated("scripts/lib.sh"))
        service = relocated("service.sh")
        self.boot = self.mod / "service.sh"
        self.boot.write_text(service)
        # A synchronous entry for one tile job; use the actual worker, including its
        # checks, lock and sleeps. A separate test exercises the whole boot script.
        self.worker = self.mod / "worker.sh"
        setup, cut, _ = service.partition("# 开机后拉起服务，不阻塞启动流程")
        if not cut:
            raise RuntimeError("cannot locate boot entry")
        self.worker.write_text(setup + 'install_pending_tile_app >>"$WATCH_LOG" 2>&1\n')
        shutil.copyfile(ROOT / "scripts/tile-app.sh", self.scripts / "tile-app.sh")
        (self.scripts / "magpie.service").write_text('echo "$1" >> "$FIX/verbs"\n')
        (self.mod / "magpie-tile.apk").write_text("fixture only\n")
        (self.mod / "tile-version").write_text("1\n")
        self.run_dir = self.owned / "run"
        self.run_dir.mkdir(parents=True)
        self.pending = self.run_dir / ".tile_pending"
        self.lock = self.run_dir / ".tile-install.flock"
        self.env = dict(PATH=f"{self.stubs}:{os.defpath}", HOME=str(self.base), FIX=str(self.base),
                        MOD=str(self.mod), FLAG=str(self.pending), MAGPIE_CONF=str(self.conf),
                        MAGPIE_WATCH_INTERVAL="997", LC_ALL="C")
        self.stub("getprop", "echo 1")
        self.stub("pm", '''case "$1" in
  list|dump) exit 0 ;;
  install) echo attempt >> "$FIX/attempts"
           [ "$(wc -l < "$FIX/attempts")" -eq "${SUCCEED_ON:-0}" ] && echo Success ;;
  disable) echo hidden >> "$FIX/hidden" ;;
  *) exit 1 ;;
esac''')
        self.stub("sleep", '''case "$1" in
  997|300) exec /bin/sleep 30 ;;  # only the whole-script fixture has a watchdog
  30|120) echo "$1" >> "$FIX/delays" ;;
  *) exit 1 ;;
esac
case "${AT_DELAY:-}" in
  disable|.uninstalling) : > "$MOD/$AT_DELAY" ;;
  cancel) rm -f "$FLAG" ;;
  gate|verbs)
    n=0
    while [ ! -s "$FIX/$AT_DELAY" ] && [ "$n" -lt 250 ]; do /bin/sleep .02; n=$((n+1)); done
    [ -s "$FIX/$AT_DELAY" ] || exit 1 ;;
esac''')

    def stub(self, name, body):
        path = self.stubs / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def harden(self, path):
        if os.path.commonpath((self.base, os.path.abspath(path))) != str(self.base):
            raise ValueError("test inputs must stay in the fixture")
        subprocess.run(["sh", "-c", '. "$1"; magpie_harden_perms "$2"', "fixture", self.lib, path],
                       env=self.env, cwd=self.base, check=True, timeout=5)

    def job(self, **env):
        subprocess.run(["sh", self.worker], env={**self.env, **env}, cwd=self.base, check=True, timeout=8)

    def spawn(self, script, **env):
        p = subprocess.Popen(["sh", script], cwd=self.base, env={**self.env, **env},
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

        def stop_fixture_group():
            # The top-level production shell starts background children. Reap *only*
            # this fixture's process group (never match host command lines or PIDs).
            if p.returncode is not None:  # already reaped the synchronous fixture worker
                return
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait(timeout=3)
        self.addCleanup(stop_fixture_group)
        return p

    def lines(self, name):
        path = self.base / name
        return path.read_text().splitlines() if path.exists() else []

    def until(self, predicate):
        deadline = time.monotonic() + 5
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("fixture did not reach requested state")
            time.sleep(.01)

    def test_only_persistent_root_and_children(self):
        for mp in (self.owned, self.owned / "profile"):
            with self.subTest(mp=mp):
                for d in (mp, mp / "bin", mp / "run", mp / "data", mp / "scripts"):
                    d.mkdir(parents=True, exist_ok=True)
                    d.chmod(0o750)
                for f in ("magpie.log", "watchdog.log.1", "magpie.pid", ".service.flock", "lan.url", "notes.log"):
                    (mp / "run" / f).touch()
                    (mp / "run" / f).chmod(0o640)
                self.harden(mp)
                self.assertEqual([mode(d) for d in (mp, mp / "bin", mp / "run", mp / "data", mp / "scripts")],
                                 [0o700, 0o755, 0o700, 0o700, 0o700])
                self.assertEqual([mode(mp / "run" / f) for f in ("magpie.log", "watchdog.log.1", "magpie.pid",
                                                                  ".service.flock", "lan.url", "notes.log")],
                                 [0o600] * 5 + [0o640])

    def test_shared_roots_lookalikes_and_legacy_configs_are_left_alone(self):
        for mp in (self.base, self.base / "data", self.adb, self.adb / "magpie-old",
                   self.adb / "modules/magpie", self.base / "legacy"):
            with self.subTest(mp=mp):
                run = mp / "run"
                run.mkdir(parents=True, exist_ok=True)
                run.chmod(0o750)
                mp.chmod(0o750)
                stopped = run / ".user_stopped"
                stopped.write_text("legacy stop intent\n")
                cfg = mp / "scripts/magpie.config"
                cfg.parent.mkdir(exist_ok=True)
                cfg.write_text("# keep legacy config\n")
                self.harden(mp)
                self.assertEqual((mode(mp), mode(run)), (0o750, 0o750))
                self.assertEqual((cfg.read_text(), stopped.read_text()),
                                 ("# keep legacy config\n", "legacy stop intent\n"))

    def test_noncanonical_spelling_does_not_authorize_chmod(self):
        self.owned.chmod(0o750)
        for suffix in ("/", "//", "/.", "/run/.."):
            with self.subTest(suffix=suffix):
                self.harden(str(self.owned) + suffix)
                self.assertEqual(mode(self.owned), 0o750)

    def test_no_chmod_via_linked_root_ancestor_or_component(self):
        other = self.base / "other"
        (other / "profile/run").mkdir(parents=True)
        target = other / "profile"
        self.owned.rename(self.adb / "saved")
        self.owned.symlink_to(other, target_is_directory=True)
        for path, real in ((self.owned, other), (self.owned / "profile", target)):
            real.chmod(0o750)
            self.harden(path)
            self.assertEqual(mode(real), 0o750)
        self.owned.unlink()
        (self.adb / "saved").rename(self.owned)
        self.run_dir.rmdir()
        self.run_dir.symlink_to(target, target_is_directory=True)
        linked_log = target / "magpie.log"
        linked_log.touch()
        linked_log.chmod(0o640)
        for name in ("scripts", "bin", "data"):
            (self.owned / name).symlink_to(target, target_is_directory=True)
        self.harden(self.owned)
        self.assertEqual((mode(target), mode(linked_log)), (0o750, 0o640))

    def test_only_single_link_regular_files(self):
        sample = self.base / "sample"
        sample.write_text("fixture\n")
        sample.chmod(0o640)
        (self.run_dir / "magpie.log").symlink_to(sample)
        os.link(sample, self.run_dir / "watchdog.log")
        fifo = self.run_dir / "magpie.pid"
        os.mkfifo(fifo, 0o600)
        fifo.chmod(0o640)
        self.harden(self.owned)
        self.assertEqual((mode(sample), mode(fifo)), (0o640, 0o640))

    def test_legacy_boot_uses_original_config_and_stop_path(self):
        old = self.base / "old layout"
        (old / "run").mkdir(parents=True)
        (old / "scripts").mkdir()
        old.chmod(0o750)
        (old / "run/.user_stopped").write_text("previous stop\n")
        (old / "scripts/magpie.config").write_text("# keep me\n")
        self.conf.write_text(f'magpie_path="{old}/"\n')
        (self.scripts / "magpie.config").write_text("# bundled\n")
        self.spawn(self.boot)
        self.until(lambda: self.lines("verbs"))
        self.assertEqual(self.lines("verbs"), ["auto-start"])
        self.assertEqual((mode(old), (old / "scripts/magpie.config").read_text(),
                          (old / "run/.user_stopped").read_text()), (0o750, "# keep me\n", "previous stop\n"))
        self.assertTrue((old / "run/watchdog.log").is_file())
        self.assertFalse((self.run_dir / "watchdog.log").exists())

    def test_seeds_private_config_only_in_a_plain_scripts_directory(self):
        (self.scripts / "magpie.config").write_text("# bundled fixture\n")
        other = self.base / "other"
        other.mkdir()
        dest = self.owned / "scripts"
        dest.symlink_to(other, target_is_directory=True)
        self.spawn(self.boot)
        self.until(lambda: len(self.lines("verbs")) == 1)
        self.assertFalse((other / "magpie.config").exists())
        dest.unlink()
        self.spawn(self.boot)
        self.until(lambda: len(self.lines("verbs")) == 2)
        cfg = dest / "magpie.config"
        self.assertEqual((cfg.read_text(), mode(cfg)), ("# bundled fixture\n", 0o600))

    def test_no_intent_or_linked_marker_never_installs(self):
        sample = self.base / "sample"
        sample.touch()
        for kind in ("absent", "symlink", "hardlink"):
            if kind == "symlink":
                self.pending.symlink_to(sample)
            if kind == "hardlink":
                self.pending.unlink()
                os.link(sample, self.pending)
            self.job(SUCCEED_ON="1")
            self.assertEqual((self.lines("attempts"), self.lines("delays"), self.lock.exists()), ([], [], False))

    def test_without_pending_still_reconciles_existing_hidden_preference(self):
        (self.run_dir / ".tile_launcher_hidden").touch()
        self.job()
        self.assertEqual((self.lines("hidden"), self.lines("attempts"), self.lock.exists()), (["hidden"], [], False))

    def test_linked_or_unavailable_lock_does_not_consume_intent(self):
        self.pending.touch()
        sample = self.base / "sample"
        sample.write_text("keep\n")
        self.lock.symlink_to(sample)
        for kind in ("linked", "unavailable"):
            if kind == "unavailable":
                self.lock.unlink()
                with self.lib.open("a") as lib:
                    lib.write("\nmagpie_pick_flock() { return 1; }\n")
            with self.assertRaises(subprocess.CalledProcessError):
                self.job()
            self.assertEqual((self.lines("attempts"), self.pending.is_file(), sample.read_text()), ([], True, "keep\n"))

    def test_failure_stops_at_budget_and_keeps_intent(self):
        self.pending.touch()
        self.job()
        self.assertEqual((len(self.lines("attempts")), self.lines("delays")), (3, ["30", "120"]))
        self.assertTrue(self.pending.is_file())
        log = (self.run_dir / "watchdog.log").read_text()
        self.assertEqual((log.count("补装失败"), log.count("下次开机再试")), (1, 1))

    def test_exhausted_batch_is_not_restarted_until_next_boot(self):
        self.pending.touch()
        self.job()
        self.job()
        self.assertEqual((len(self.lines("attempts")), self.lines("delays")), (3, ["30", "120"]))
        self.boot_id.write_text("00000000-0000-0000-0000-000000000002\n")
        self.job(SUCCEED_ON="4")
        self.assertEqual((len(self.lines("attempts")), self.pending.exists()), (4, False))

    def test_missing_boot_id_still_allows_one_bounded_batch(self):
        self.boot_id.unlink()
        self.pending.touch()
        self.job()
        self.assertEqual((len(self.lines("attempts")), self.lines("delays"), self.pending.exists()),
                         (3, ["30", "120"], True))

    def test_success_without_first_retry(self):
        self.pending.touch()
        self.job(SUCCEED_ON="1")
        self.assertEqual((len(self.lines("attempts")), self.lines("delays"), self.pending.exists()), (1, [], False))

    def test_real_boot_retries_without_binary_and_does_not_delay_auto_start(self):
        # No bin/magpie. Delay 30 cannot complete until the stub controller was
        # actually called. Late successful installation reconciles the saved icon.
        self.pending.touch()
        (self.run_dir / ".tile_launcher_hidden").touch()
        self.spawn(self.boot, SUCCEED_ON="2", AT_DELAY="verbs")
        self.until(lambda: not self.pending.exists() and len(self.lines("hidden")) == 2)
        self.assertEqual((len(self.lines("attempts")), self.lines("delays"), self.lines("verbs")),
                         (2, ["30"], ["auto-start"]))

    def test_lock_serializes_the_whole_retry_batch(self):
        self.pending.touch()
        first = self.spawn(self.worker, AT_DELAY="gate", SUCCEED_ON="2")
        self.until(lambda: self.lines("delays"))
        self.job()  # Another service invocation arrives while the first is sleeping.
        self.assertEqual(len(self.lines("attempts")), 1)
        (self.base / "gate").write_text("continue\n")
        self.assertEqual(first.wait(timeout=5), 0)
        self.assertEqual((len(self.lines("attempts")), self.pending.exists()), (2, False))

    def test_module_or_intent_withdrawn_during_backoff(self):
        for change in ("disable", ".uninstalling", "cancel"):
            with self.subTest(change=change):
                self.pending.touch()
                self.job(AT_DELAY=change)
                self.assertEqual((len(self.lines("attempts")), self.lines("delays"), self.pending.exists()),
                                 (1, ["30"], change != "cancel"))
                (self.base / "attempts").unlink()
                (self.base / "delays").unlink()
                (self.mod / change).unlink(missing_ok=True)

    def test_missing_helper_does_not_discard_intent(self):
        self.pending.touch()
        (self.scripts / "tile-app.sh").unlink()
        self.job()
        self.assertEqual((self.lines("attempts"), self.pending.is_file()), ([], True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
