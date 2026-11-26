#!/usr/bin/env python3
"""Offline integration tests for the tile versionCode Git-tree gate.

Every case uses a disposable local Git repository: no network, credentials,
repository refs, Android tooling, APKs, or release artifacts are touched.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/ci/check-tile-version.py"
MANIFEST = '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.ruin.magpie.tile" android:versionCode="{code}"
    android:versionName="{name}">
  <uses-sdk android:minSdkVersion="29" android:targetSdkVersion="37" />
</manifest>
'''


class TileVersionGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tile-version-git-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Offline Test")
        self.git("config", "user.email", "offline@example.invalid")
        self.put("tile-app/AndroidManifest.xml", MANIFEST.format(code=10, name="1.0"))
        self.put("tile-app/src/Tile.java", "class Tile { int state = 1; }\n")
        self.put("tile-app/res/values/strings.xml", "<resources><string name=\"a\">A</string></resources>\n")
        binary_resource = self.repo / "tile-app/res/drawable-hdpi/ic_tile.png"
        binary_resource.parent.mkdir(parents=True)
        binary_resource.write_bytes(b"\x89PNG\r\n\x1a\nfixture")
        self.put("README.md", "initial docs\n")
        self.commit("baseline")

    def git(self, *args, check=True):
        p = subprocess.run(["git", "-C", str(self.repo), *args], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and p.returncode:
            self.fail("git command failed: " + p.stderr)
        return p

    def put(self, rel, text):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-qm", message)

    def gate(self, *args):
        return subprocess.run([sys.executable, str(GATE), "--repo", str(self.repo), *args],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def tag_baseline(self):
        self.git("tag", "v1.0")

    def test_runtime_change_without_bump_fails(self):
        self.tag_baseline()
        self.put("tile-app/src/Tile.java", "class Tile { int state = 2; }\n")
        self.commit("runtime change without bump")
        result = self.gate()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("必须高于基线", result.stderr)

    def test_runtime_change_with_bump_passes(self):
        self.tag_baseline()
        self.put("tile-app/src/Tile.java", "class Tile { int state = 2; }\n")
        self.put("tile-app/AndroidManifest.xml", MANIFEST.format(code=11, name="1.1"))
        self.commit("runtime change with bump")
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("10 → 11", result.stdout)

    def test_documentation_only_does_not_require_bump(self):
        self.tag_baseline()
        self.put("README.md", "docs only changed\n")
        self.commit("documentation only")
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("运行时内容未变", result.stdout)

    def test_first_release_without_history_tag_passes(self):
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("首次发布", result.stdout)

    def test_missing_explicit_baseline_fails_closed(self):
        result = self.gate("--base-ref", "refs/heads/not-fetched")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("基线不可用或缺失", result.stderr)

    def test_current_release_tag_is_excluded_from_baseline(self):
        self.tag_baseline()
        self.put("tile-app/src/Tile.java", "class Tile { int state = 3; }\n")
        self.put("tile-app/AndroidManifest.xml", MANIFEST.format(code=10, name="1.1"))
        self.commit("new release tag with missing bump")
        self.git("tag", "v1.1")
        result = self.gate("--current-tag", "v1.1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("基线 v1.0=10", result.stderr)

    def test_new_tag_is_valid_first_release_and_self_tag_is_not_baseline(self):
        self.git("tag", "v1.0")
        result = self.gate("--current-tag", "v1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("没有可用的前序发布 tag", result.stdout)

    def test_ci_rerun_at_existing_tag_uses_same_commit_as_baseline(self):
        self.tag_baseline()
        self.put("tile-app/src/Tile.java", "class Tile { int state = 2; }\n")
        self.commit("already released tile update")
        self.git("tag", "v1.1")
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("基线 v1.1", result.stdout)

    def test_shallow_checkout_fails_instead_of_skipping_history(self):
        head = self.git("rev-parse", "HEAD").stdout.strip()
        (self.repo / ".git/shallow").write_text(head + "\n", encoding="ascii")
        result = self.gate()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("shallow checkout", result.stderr)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TileVersionGateTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
