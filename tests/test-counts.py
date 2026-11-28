"""Exercise the real CI entry points with tiny, observable suites instead of rerunning them."""
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class CountRunnerTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="magpie-runner-test.")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.tests = self.root / "tests"
        self.tests.mkdir()
        for name in ("run-all.sh", "check-counts.sh", "check-counts.py", "make-fixtures.py"):
            shutil.copyfile(HERE / name, self.tests / name)
        self.suites = sorted(p.name for p in HERE.glob("test-*.sh"))
        self.assertEqual(len(self.suites), 6)
        for name in self.suites + ["run-jvm.sh"]:
            (self.tests / name).write_text('''set -eu
name=${0##*/}
printf '%s\\t%s\\t%s\\n' "$name" "$TEST_BASE" "${TEST_SRV:-}" >> "$TRACE"
case "$name" in
  test-install.sh|test-action.sh) python3 "$PROBE" ;;
  run-jvm.sh) echo '== jvm/FixtureTest' ;;
esac
echo '  PASS  one counted assertion'
''')
        # The two overlapping runs must serve their own manifests from the bound sockets.
        probe = self.root / "probe.py"
        probe.write_text('''import json, os, time, urllib.request
from pathlib import Path
base = os.environ['TEST_SRV']
assert base.startswith('http://127.0.0.1:')
if 'BARRIER' in os.environ:
    barrier = Path(os.environ['BARRIER'])
    (barrier / Path(os.environ['TRACE']).name).touch()
    deadline = time.monotonic() + 8
    while len(list(barrier.iterdir())) < 2:
        if time.monotonic() >= deadline: raise SystemExit('fixture overlap timeout')
        time.sleep(.03)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(base + '/manifest.json', timeout=3) as response:
    url = json.load(response)['assets']['magpie-cli-android-arm64']['url']
assert url == base + '/fake-bin', (url, base)
''')
        # sh -n and ShellCheck only see empty placeholders. The other Python suites
        # are also placeholders; this test is about the runner, not nesting real tests.
        for name in ("service.sh", "action.sh", "uninstall.sh", "customize.sh", "build.sh", "tile-app/build.sh",
                     "scripts/magpie.service", "scripts/empty.sh", "scripts/ci/empty.sh", "system/bin/magpie",
                     "META-INF/com/google/android/update-binary"):
            path = self.root / name
            path.parent.mkdir(exist_ok=True, parents=True)
            path.touch()
        for path in HERE.glob("test-*.py"):
            (self.tests / path.name).touch()
        (self.tests / "test-webui.js").touch()
        cn = "6 条断言，1 条 JVM 用例（`FixtureTest` 1）。\n"
        (self.root / "README.md").write_text(cn)
        (self.root / "README_EN.md").write_text("6 assertions total; 1 JVM cases\n")
        (self.tests / "README.md").write_text(cn + "".join(f"| `{s}` | 1 | fixture |\n" for s in self.suites))
        (self.root / "module.prop").write_text("version=v1\n")
        (self.root / "CHANGELOG.md").write_text("## v1\n6 条断言（1 + 1 + 1 + 1 + 1 + 1）。\n")
        self.tmpdir = self.root / "tmp"
        self.tmpdir.mkdir()
        self.env = dict(os.environ, TMPDIR=str(self.tmpdir), TEST_BASE=str(self.root / "must-not-use"),
                        TEST_SRV="", PROBE=str(probe))

    def invoke(self, entry="check-counts.sh", trace="trace", **env):
        return subprocess.run(["sh", str(self.tests / entry)], cwd=self.root,
                              env=dict(self.env, TRACE=str(self.root / trace), **env), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)

    def test_once_and_isolated_in_parallel(self):
        barrier = self.root / "barrier"
        barrier.mkdir()
        with ThreadPoolExecutor(2) as pool:
            jobs = [pool.submit(self.invoke, entry, tag, BARRIER=str(barrier))
                    for entry, tag in (("run-all.sh", "ci"), ("check-counts.sh", "standalone"))]
            for job in jobs:
                result = job.result()
                self.assertEqual(result.returncode, 0, result.stdout)
        addresses, bases = set(), set()
        for tag in ("ci", "standalone"):
            lines = [line.split("\t") for line in (self.root / tag).read_text().splitlines()]
            self.assertEqual(Counter(line[0] for line in lines), Counter(self.suites + ["run-jvm.sh"]))
            urls = {url for name, _, url in lines if name in ("test-install.sh", "test-action.sh")}
            self.assertEqual(len(urls), 1)
            addresses.update(urls)
            for _, base, _ in lines:
                self.assertIn(self.tmpdir, Path(base).parents)
                self.assertNotIn(base, bases)
                bases.add(base)
        self.assertEqual(len(addresses), 2)
        self.assertFalse(list(self.tmpdir.iterdir()))

    def test_nonzero_status_fail_line_and_empty_output_cannot_pass(self):
        for name, body, detail in (("test-install.sh", "echo '  PASS  partial'; exit 42", "exit=42"),
                                   ("run-jvm.sh", "echo '  PASS  partial'; echo '  FAIL  late'", "FAIL=1"),
                                   ("test-service.sh", "exit 0", "PASS=0")):
            script = self.tests / name
            original = script.read_text()
            with self.subTest(name=name):
                script.write_text(body + "\n")
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(detail, result.stdout)
                self.assertNotIn("文档与实际一致", result.stdout)
                self.assertFalse(list(self.tmpdir.iterdir()))
            script.write_text(original)

    def test_stale_totals_and_unreleased_section_rejected(self):
        (self.root / "README.md").write_text("16 条断言，11 条 JVM 用例\n")
        history = self.root / "CHANGELOG.md"
        history.write_text("## 未发布\n1 + 1 + 1 + 1 + 1 + 1\n" + history.read_text())
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        for message in ("README.md 缺少 6 条断言", "README.md 缺少 1 条 JVM 用例", "CHANGELOG.md (未发布) 缺少 6"):
            self.assertIn(message, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
