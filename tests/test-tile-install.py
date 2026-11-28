#!/usr/bin/env python3
"""Exercise the real flash script and tile helper; no device, real pm, permissions or APKs."""
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PKG = "com.ruin.magpie.tile"
UP = "/dev/input/event2: EV_KEY  KEY_VOLUMEUP  DOWN\n"
DOWN = "EV_KEY  KEY_VOLUMEDOWN  DOWN\n"
NOISE = ("EV_SYN SYN_REPORT 00000000\nEV_KEY KEY_POWER DOWN\n"
         "EV_KEY KEY_VOLUMEUP UP\nEV_KEY KEY_VOLUMEDOWN REPEAT\n"
         "EV_KEY KEY_VOLUMEUP DOWNSTREAM\nEV_ABS KEY_VOLUMEUP DOWN\n")


class TileInstallTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="magpie-tile-install-")
        self.addCleanup(tmp.cleanup)
        self.fx = Path(tmp.name).resolve()
        self.bin = self.fx / "bin"
        self.mod = self.fx / "module with spaces"
        self.mp = self.fx / "user data"
        self.run_dir = self.mp / "run"
        self.pending = self.run_dir / ".tile_pending"
        self.apk = self.mod / "magpie-tile.apk"
        self.version = self.mod / "tile-version"
        self.calls = self.fx / "pm-calls"
        self.keys = self.fx / "events"
        self.pids = self.fx / "input-pids"
        self.bin.mkdir()
        (self.mod / "scripts").mkdir(parents=True)
        inputs = self.fx / "dev/input"
        inputs.mkdir(parents=True)
        (inputs / "event0").touch()
        # Relocate the device roots in fixture copies only. Never expose ambient
        # PATH, su, real getevent/pm, /dev/input or a manager's install functions.
        for name in ("customize.sh", "scripts/lib.sh", "scripts/tile-app.sh"):
            src = (ROOT / name).read_text(encoding="utf-8")
            (self.mod / name).write_text(src.replace("/data/adb", str(self.fx / "data/adb"))
                                       .replace("/dev/input", str(inputs)), encoding="utf-8")
        self.conf = self.fx / "user.config"
        self.conf.write_text(f'magpie_path="{self.mp}"\nMAGPIE_DNS=\n')
        self.apk.write_bytes(b"inert fixture, not an APK")
        self.version.write_text("2\n")
        self.env = dict(PATH=str(self.bin), HOME=str(self.fx), TMPDIR=str(self.fx),
                        FX=str(self.fx), MODPATH=str(self.mod), MAGPIE_CONF=str(self.conf),
                        LC_ALL="C", PYTHONDONTWRITEBYTECODE="1")
        for name in ("sh", "awk", "sed", "tr", "head", "grep", "stat", "mktemp", "mkfifo", "mkdir", "mv", "rmdir"):
            tool = shutil.which(name, path=os.defpath)
            if not tool:
                self.fail("missing fixture tool: " + name)
            (self.bin / name).symlink_to(tool)
        # Even if production code regresses, rm can only unlink files under FX.
        self.python_stub("rm", '''import os, sys
from pathlib import Path
root = Path(os.environ['FX'])
for arg in sys.argv[1:]:
    if arg == '-f': continue
    p = Path(arg)
    p.parent.resolve().relative_to(root)
    if p.name in ('', '.', '..') or arg.startswith('-'): sys.exit(90)
    if p.name == '.tile_pending' and os.environ.get('FAIL_CLEAR'): sys.exit(1)
    p.unlink(missing_ok=True)
''')
        self.python_stub("pm", '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with (Path(os.environ['FX']) / 'pm-calls').open('a') as f: print(json.dumps(args), file=f)
verb = args[0].upper()
if verb not in ('LIST', 'INSTALL', 'UNINSTALL'): sys.exit(90)
sys.stdout.write(os.environ.get(verb, '' if verb == 'LIST' else 'Success\\n'))
sys.stderr.write(os.environ.get(verb + '_ERR', ''))
sys.exit(int(os.environ.get(verb + '_RC', 0)))
''')
        self.python_stub("getevent", '''import os, sys, time
from pathlib import Path
fx = Path(os.environ['FX'])
if '-lp' in sys.argv:
    print('KEY_VOLUMEUP KEY_VOLUMEDOWN'); sys.exit(0)
with (fx / 'input-pids').open('a') as f: print(os.getpid(), file=f)
s = (fx / 'events').read_text()
if '-qlc' in sys.argv: s = ''.join(s.splitlines(True)[:1])
sys.stdout.write(s); sys.stdout.flush()
mode = os.environ.get('EVENT_MODE', '')
if mode == 'quiet': time.sleep(4)  # a valid choice must not wait for another event/EOF
if mode == 'noise':
    for _ in range(150):
        print('EV_SYN SYN_REPORT 0', flush=True); time.sleep(.02)
''')
        # Assert the *production* budget is 15s; shorten it only in this sandbox.
        timer = shlex.quote(shutil.which("timeout", path=os.defpath))
        self.stub("timeout", '#!/bin/sh\n[ "$1" = 15 ] || exit 90\n'
                  'echo "$1" >> "$FX/windows"; shift\n'
                  f'exec {timer} "${{SHORT_WINDOW:-2}}" "$@"\n')

    def stub(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o700)

    def python_stub(self, name, source):
        self.stub(name, "#!" + sys.executable + "\n" + source)

    def shell(self, script, **env):
        return subprocess.run([str(self.bin / "sh"), "-c", script], env={**self.env, **env},
                              cwd=self.fx, text=True, encoding="utf-8", capture_output=True, timeout=7)

    def flash(self, events="", **env):
        self.keys.write_text(events)
        result = self.shell('umask 000; set_perm() { :; }; set_perm_recursive() { :; }; '
                            'ui_print() { printf "%s\\n" "$*"; }; . "$MODPATH/customize.sh"', **env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(list(self.fx.glob(".tile-keys.*")), "temporary input FIFO leaked")
        if self.pids.exists():
            for pid in self.pids.read_text().splitlines():
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid), 0)  # existence check only, no signal
        return result.stdout

    def helper(self, function, **env):
        return self.shell('. "$MODPATH/scripts/tile-app.sh"; ' + function, **env)

    def pm_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def assert_install_only(self):
        self.assertEqual(self.pm_calls(), [["list", "packages", "--show-versioncode", PKG],
                                           ["install", "-r", str(self.apk)]])

    def old_marker(self):
        self.run_dir.mkdir(parents=True)
        self.pending.write_text("old explicit intent\n")

    def test_noise_then_up_installs_once_and_clears_old_marker(self):
        self.old_marker()
        out = self.flash(NOISE + UP + DOWN, EVENT_MODE="quiet")
        self.assertIn("磁贴 App 已安装", out)
        self.assert_install_only()
        self.assertFalse(self.pending.exists())

    def test_down_revokes_only_pending_no_install_or_uninstall(self):
        self.old_marker()
        for other in (".tile_launcher_hidden", ".tile-install.flock"):
            (self.run_dir / other).write_text("keep")
        self.assertIn("已跳过", self.flash(DOWN + UP))
        self.assertEqual(self.pm_calls(), [])
        self.assertFalse(self.pending.exists())
        self.assertEqual([p.read_text() for p in self.run_dir.iterdir()], ["keep", "keep"])

    def test_noise_and_eof_never_install_or_create_a_run_directory(self):
        self.flash(NOISE)
        self.assertEqual(self.pm_calls(), [])
        self.assertFalse(self.run_dir.exists())

    def test_repeated_noise_does_not_restart_the_deadline(self):
        self.flash(NOISE, EVENT_MODE="noise", SHORT_WINDOW="0.5")
        self.assertEqual((self.fx / "windows").read_text().splitlines(), ["15"])
        self.assertEqual(self.pm_calls(), [])
        self.assertFalse(self.pending.exists())

    def test_no_new_choice_does_not_overwrite_previous_explicit_consent(self):
        self.old_marker()
        self.flash("", EVENT_MODE="quiet", SHORT_WINDOW="0.5")
        self.assertEqual(self.pending.read_text(), "old explicit intent\n")
        self.assertEqual(self.pm_calls(), [])

    def test_missing_getevent_or_timeout_defaults_to_no_new_request(self):
        for name in ("getevent", "timeout"):
            with self.subTest(name=name):
                tool = self.bin / name
                tool.rename(self.bin / "held")
                self.flash(UP)
                self.assertFalse(self.pids.exists())
                self.assertFalse(self.run_dir.exists())
                self.assertEqual(self.pm_calls(), [])
                (self.bin / "held").rename(tool)

    def test_pm_fails_positive_choice_creates_private_regular_marker(self):
        out = self.flash(UP, INSTALL="Success\n", INSTALL_RC="1")
        self.assert_install_only()
        self.assertIn("已记为", out)
        self.assertNotIn("磁贴 App 已安装", out)
        st = self.pending.lstat()
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual((stat.S_IMODE(st.st_mode), st.st_nlink, st.st_size), (0o600, 1, 0))
        self.assertEqual(stat.S_IMODE(self.run_dir.stat().st_mode), 0o700)

    def test_failure_creating_run_not_reported_as_deferred(self):
        self.mp.mkdir()
        self.run_dir.write_text("not a directory")
        out = self.flash(UP, INSTALL="Failure [rejected]\n")
        self.assertIn("未能记录", out)
        self.assertNotIn("已记为", out)
        self.assertEqual(self.run_dir.read_text(), "not a directory")

    def test_failure_publishing_marker_preserves_old_file_and_cleans_temp(self):
        self.old_marker()
        (self.bin / "mv").unlink()
        self.stub("mv", "#!/bin/sh\nexit 1\n")
        out = self.flash(UP, INSTALL_RC="1")
        self.assertIn("未能记录", out)
        self.assertNotIn("已记为", out)
        self.assertEqual(list(self.run_dir.iterdir()), [self.pending])
        self.assertEqual(self.pending.read_text(), "old explicit intent\n")

    def test_failure_revoking_marker_warns_not_silent_skip(self):
        self.old_marker()
        self.assertIn("未能清除", self.flash(DOWN, FAIL_CLEAR="1"))
        self.assertTrue(self.pending.exists())
        self.assertEqual(self.pm_calls(), [])

    def test_symlinked_run_does_not_redirect_marker_updates(self):
        self.mp.mkdir()
        target = self.fx / "other run"
        target.mkdir()
        other = target / self.pending.name
        other.write_text("keep")
        self.run_dir.symlink_to(target)
        self.assertIn("未能记录", self.flash(UP, INSTALL_RC="1"))
        self.assertIn("未能清除", self.flash(DOWN))
        self.assertEqual(other.read_text(), "keep")

    def test_special_markers_are_never_followed_or_truncated(self):
        self.run_dir.mkdir(parents=True)
        target = self.fx / "other file"
        target.write_text("keep")
        target.chmod(0o640)
        for kind in ("symlink", "hardlink", "fifo", "directory"):
            with self.subTest(kind=kind):
                if kind == "symlink": self.pending.symlink_to(target)
                elif kind == "hardlink": os.link(target, self.pending)
                elif kind == "fifo": os.mkfifo(self.pending)
                else: self.pending.mkdir()
                self.assertIn("未能记录", self.flash(UP, INSTALL_RC="1"))
                self.assertEqual((target.read_text(), stat.S_IMODE(target.stat().st_mode)), ("keep", 0o640))
                if kind == "directory": self.pending.rmdir()
                else: self.pending.unlink()

    def test_missing_apk_does_not_ask_or_invoke_pm(self):
        self.apk.unlink()
        self.flash(UP)
        self.assertFalse(self.pids.exists())
        self.assertEqual(self.pm_calls(), [])
        self.assertFalse(self.run_dir.exists())

    def test_damaged_optional_helper_does_not_abort_the_module_flash(self):
        (self.mod / "scripts/tile-app.sh").write_text("broken_helper() {\n")
        out = self.flash(UP)
        self.assertIn("已记为", out)
        self.assertNotIn("磁贴 App 已安装", out)
        self.assertTrue(self.pending.is_file())
        self.assertEqual(self.pm_calls(), [])

    def test_literal_package_and_complete_version_field_only(self):
        listings = (f"package:{PKG}.debug versionCode:9\n"
                    "package:comXruinXmagpieXtile versionCode:8\n"
                    f"package:{PKG} versionCode:7junk\n"
                    f"package:{PKG}\tversionCode:1\tuid:10123\r\n")
        parsed = self.helper('tile_installed_code', LIST=listings)
        self.assertEqual((parsed.returncode, parsed.stdout), (0, "1\n"))
        self.calls.unlink()
        result = self.helper('tile_install "$MODPATH"', LIST=listings)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_install_only()

    def test_exact_current_or_newer_version_skips_pm_install(self):
        self.old_marker()
        out = self.flash(UP, LIST=f"package:{PKG} versionCode:200\r\n")
        self.assertIn("磁贴 App 已安装", out)
        self.assertEqual(self.pm_calls(), [["list", "packages", "--show-versioncode", PKG]])
        self.assertFalse(self.pending.exists())

    def test_failed_list_does_not_accept_its_plausible_partial_output(self):
        result = self.helper('tile_install "$MODPATH"', LIST=f"package:{PKG} versionCode:99\n", LIST_RC="9")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_install_only()  # explicitly selected, but no downgrade flag or permission grant

    def test_version_sidecar_is_one_bounded_decimal_not_digit_scraping(self):
        for raw in ("1.2\n", "v2\n", "3extra", "2\n3\n", "2\n\n", "0\n", "2147483648\n", ""):
            with self.subTest(raw=raw):
                self.version.write_text(raw)
                result = self.helper('tile_bundled_code "$MODPATH"')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.version.write_bytes(b"2147483647\r\n")
        result = self.helper('tile_bundled_code "$MODPATH"')
        self.assertEqual((result.returncode, result.stdout), (0, "2147483647\n"))

    def test_install_and_uninstall_need_pm_status_and_terminal_success(self):
        cases = (("Performing Streamed Install\nSuccess\r\n\n", "", "0", True),
                 ("Success\n", "", "3", False), ("Failure [Not Success]\n", "", "0", False),
                 ("Success\nFailure [error]\n", "", "0", False), ("", "Success\n", "0", False),
                 ("", "", "0", False))
        for verb, func in (("INSTALL", 'tile_install "$MODPATH"'), ("UNINSTALL", "tile_uninstall")):
            for out, err, code, success in cases:
                with self.subTest(verb=verb, out=out, err=err, code=code):
                    self.calls.unlink(missing_ok=True)
                    result = self.helper(func, **{verb: out, verb + "_ERR": err, verb + "_RC": code})
                    self.assertEqual(result.returncode == 0, success)
                    if verb == "INSTALL":
                        self.assert_install_only()
                        self.assertEqual("已安装" in result.stdout, success)
                    else:
                        self.assertEqual(self.pm_calls(), [["uninstall", PKG]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
