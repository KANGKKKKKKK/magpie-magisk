"""Regression checks for exits, configuration writes and ownership. No device or real signals."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def function(file, name, end='}'):
    text = (ROOT / file).read_text()
    start = text.index('\n' + name + '()') + 1
    return text[start:text.index('\n' + end + '\n', start) + 2] + '\n'


class RuntimeBoundaries(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix='magpie-runtime.')
        self.addCleanup(work.cleanup)
        self.d = Path(work.name).resolve()
        self.env = dict(PATH=os.defpath, HOME=str(self.d), TMPDIR=str(self.d),
                        MODDIR=str(self.d), RUN=str(self.d / 'run'))

    def shell(self, code, *args, **env):
        return subprocess.run(['sh', '-c', code, 'fixture', *map(str, args)], cwd=self.d,
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=8)

    def test_cli_exports_configured_address_home_and_arguments(self):
        scripts = self.d / 'scripts'
        scripts.mkdir()
        shutil.copy(ROOT / 'scripts/lib.sh', scripts)
        shutil.copy(ROOT / 'scripts/magpie-cli.sh', scripts)
        bindir = self.d / 'bin'
        bindir.mkdir()
        binary = bindir / 'magpie'
        binary.write_text('#!/bin/sh\nprintf "%s\\n" "$MAGPIE_ADDR" "$MAGPIE_HOME" "$1"\n')
        binary.chmod(0o755)
        conf = self.d / 'config'
        conf.write_text(f'magpie_path="{self.d}"\nMAGPIE_ADDR="127.0.0.1:9123"\n')
        r = self.shell('sh "$1" "one argument"', scripts / 'magpie-cli.sh', MAGPIE_CONF=str(conf))
        self.assertEqual((r.returncode, r.stdout.splitlines()),
                         (0, ['127.0.0.1:9123', str(self.d / 'data'), 'one argument']), r.stderr)

    def test_compatibility_link_is_non_destructive_and_idempotent(self):
        cli = self.d / 'scripts/magpie-cli.sh'
        cli.parent.mkdir()
        cli.touch(mode=0o755)
        links = [self.d / 'hosts' / p / 'magpie' for p in ('ksu/bin', 'magisk', 'ap/bin')]
        for entry in links:
            entry.parent.mkdir(parents=True)
        links[0].write_text('pre-existing command\n')
        links[1].symlink_to('external-missing-tool')
        script = function('scripts/magpie.service', 'ensure_cli').replace('/data/adb', str(self.d / 'hosts'))
        for _ in range(2):
            r = self.shell(script + 'log() { :; }; ensure_cli')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(links[0].read_text(), 'pre-existing command\n')
            self.assertEqual(os.readlink(links[1]), 'external-missing-tool')
            self.assertEqual(links[2].resolve(strict=True), cli)

    def test_old_dns_ownership_requires_more_than_the_listen_address(self):
        proc = self.d / 'proc/42'
        proc.mkdir(parents=True)
        (proc / 'exe').symlink_to('/system/bin/dnsmasq')
        run = self.d / 'run'
        fn = function('scripts/magpie.service', 'legacy_pid_matches', ')').replace('/proc/', str(self.d / 'proc') + '/')
        for pidfile, valid in ((run / 'dnsmasq.pid', True), (self.d / 'some-other.pid', False)):
            with self.subTest(pidfile=pidfile):
                (proc / 'cmdline').write_bytes(b'dnsmasq\0--listen-address=::1\0--pid-file=' + os.fsencode(pidfile) + b'\0')
                self.assertEqual(self.shell(fn + 'legacy_pid_matches 42 dnsmasq').returncode == 0, valid)

    def test_switch_gateway_never_publishes_partial_config(self):
        conf = self.d / 'user.conf'
        original = 'MAGPIE_ADDR="127.0.0.1:9100"\n# Keep user settings\n'
        conf.write_text(original)
        code = function('action.sh', 'write_conf_host') + '''
sed() { printf '# partially generated\\n'; return 1; }
write_conf_host 0.0.0.0
'''
        r = self.shell(code, CONF=str(conf), API_PORT='9100', WEB_PORT='9200')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(conf.read_text(), original)
        self.assertEqual(list(self.d.glob('user.conf.tmp.*')), [])

    def test_diagnostics_preserve_existing_data_and_do_not_write(self):
        (self.d / 'data').mkdir()
        sentinel = self.d / 'data/.doctor'
        sentinel.write_text('not a temp file\n')
        before = sentinel.stat().st_mtime_ns
        body = (ROOT / 'scripts/doctor.sh').read_text().split('echo "[10/10] 日志与磁盘"\n', 1)[1]
        r = self.shell('ok() { :; }; warn() { :; }; bad() { exit 9; }; OK=0; WARN=0; BAD=0\n' + body,
                       magpie_path=str(self.d))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sentinel.read_text(), 'not a temp file\n')
        self.assertEqual(sentinel.stat().st_mtime_ns, before)

    def test_recovery_wrapper_propagates_manager_exit(self):
        recovery = (ROOT / 'META-INF/com/google/android/update-binary').read_text()
        util = self.d / 'util.sh'
        recovery = recovery.replace('/data/adb/magisk/util_functions.sh', str(util))
        for rc in (0, 19):
            util.write_text(f'install_module() {{ return {rc}; }}\n')
            self.assertEqual(self.shell('mount() { :; }\n' + recovery).returncode, rc)

    def test_old_watchdog_cannot_resume_against_replacement_directory(self):
        mod = self.d / 'module'
        mod.mkdir()
        fn = function('service.sh', 'boot_module_active')
        r = self.shell(fn + '''cd "$MODDIR" && BOOT_DIR_ID=$(stat -c '%d:%i' .) && boot_module_active || exit 2
mv "$MODDIR" "$MODDIR.old" && mkdir "$MODDIR" || exit 3
if boot_module_active; then exit 4; fi
''', MODDIR=str(mod))
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
