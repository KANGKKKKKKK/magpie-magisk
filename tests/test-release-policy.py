#!/usr/bin/env python3
"""Local release payload / policy regressions. Never uses GitHub credentials or a network."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "scripts/ci/release-artifacts.py"


class ReleasePayloadTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="magpie-release-policy-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.src = self.base / "source"
        self.src.mkdir()
        for name in ("LICENSE", "module.prop", "action.sh", "customize.sh", "service.sh", "uninstall.sh"):
            shutil.copyfile(ROOT / name, self.src / name)
        for name in ("scripts", "system", "webroot", "META-INF", "tile-app"):
            shutil.copytree(ROOT / name, self.src / name, ignore=shutil.ignore_patterns("build", "__pycache__"))
        self.apk = self.base / "magpie-tile.apk"
        self.apk.write_bytes(b"synthetic APK bytes; signature is tested by the real APK verifier separately")
        # 文件名随 module.prop 的版本走；写死版本号会让每次发版都把这组用例弄红。
        version = next(l.split("=", 1)[1].strip() for l in (ROOT / "module.prop").read_text().splitlines()
                       if l.startswith("version="))
        self.version = version
        self.zip = self.base / f"dist/magpie-{version}.zip"

    def call(self, *args, ok=True):
        result = subprocess.run(["python3", "-I", str(POLICY), *map(str, args)], cwd=self.base,
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def pack(self, *extra):
        self.call("package", "--source", self.src, "--apk", self.apk, "--output", self.zip.parent, *extra)

    def verify(self, *extra, ok=True):
        return self.call("verify", "--source", self.src, "--file", self.zip, *extra, ok=ok)

    def rewrite(self, name, contents):
        tmp = self.zip.with_suffix(".new")
        with zipfile.ZipFile(self.zip) as source, zipfile.ZipFile(tmp, "w") as target:
            for entry in source.infolist():
                if entry.filename != name:
                    target.writestr(entry, source.read(entry))
                elif contents is not None:
                    target.writestr(entry, contents)
        tmp.replace(self.zip)

    def test_payload_includes_license_and_no_ci_files(self):
        self.pack()
        with zipfile.ZipFile(self.zip) as packaged:
            self.assertEqual(packaged.read("LICENSE"), (ROOT / "LICENSE").read_bytes())
            self.assertFalse(any(f.startswith("scripts/ci/") for f in packaged.namelist()))
            self.assertTrue(packaged.getinfo("service.sh").external_attr >> 16 & stat.S_IXUSR)
            self.assertIn("scripts/lib.sh", packaged.namelist())
            self.assertIn("system/etc/resolv.conf", packaged.namelist())
        self.assertEqual(json.loads(self.verify().stdout)["version"], self.version)

    def test_incomplete_package_is_not_accepted(self):
        self.pack()
        self.rewrite("scripts/lib.sh", None)
        self.verify(ok=False)

    def test_wrong_source_bytes_are_not_accepted(self):
        self.pack()
        self.rewrite("service.sh", b"not from the tag\n")
        self.verify(ok=False)

    def test_package_reads_git_objects_instead_of_worktree(self):
        def git(*args):
            return subprocess.check_output(["git", "-C", str(self.src), *args], text=True,
                                           env={**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}, timeout=8)
        git("init", "-q")
        git("add", "--", ".")
        git("-c", "user.name=Audit Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        ref = git("rev-parse", "HEAD").strip()
        original = (self.src / "action.sh").read_bytes()
        (self.src / "action.sh").write_bytes(b"untracked working-tree changes are ignored")
        self.pack("--git-ref", ref)
        self.verify("--git-ref", ref)
        with zipfile.ZipFile(self.zip) as z:
            self.assertEqual(z.read("action.sh"), original)

    def test_unwrap_only_accepts_exact_unsigned_artifact(self):
        outer = self.base / "artifact.zip"
        out = self.base / "unpacked"
        with zipfile.ZipFile(outer, "w") as z:
            z.writestr("magpie-tile-unsigned.apk", b"fixture")
        self.call("unwrap", "unsigned", outer, out)
        self.assertEqual((out / "magpie-tile-unsigned.apk").read_bytes(), b"fixture")
        self.call("unwrap", "unsigned", outer, out, ok=False)

    def test_unwrap_rejects_additional_or_nonregular_entries(self):
        outer = self.base / "artifact.zip"
        out = self.base / "unpacked"
        with zipfile.ZipFile(outer, "w") as z:
            z.writestr("magpie-tile-unsigned.apk", b"fixture")
            z.writestr("README.md", b"not part of the artifact")
        self.call("unwrap", "unsigned", outer, out, ok=False)
        link = zipfile.ZipInfo("magpie-tile-unsigned.apk")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(outer, "w") as z:
            z.writestr(link, b"other")
        self.call("unwrap", "unsigned", outer, out, ok=False)
        self.assertFalse(out.exists())

    def test_unwrap_rejects_duplicate_entries(self):
        outer = self.base / "artifact.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(outer, "w") as z:
                z.writestr("magpie-tile-unsigned.apk", b"first")
                z.writestr("magpie-tile-unsigned.apk", b"second")
        self.call("unwrap", "unsigned", outer, self.base / "unpacked", ok=False)

    def flow_function(self, name):
        text = (ROOT / "scripts/ci/release-flow.sh").read_text()
        start = text.index("\n" + name + "() {") + 1
        return text[start:text.index("\n}", start) + 2]

    def test_handoff_binds_run_attempt_and_archive_digest(self):
        outer = self.base / "source-artifact.zip"
        with zipfile.ZipFile(outer, "w") as z:
            z.writestr("magpie-tile-unsigned.apk", b"fixture")
        digest = hashlib.sha256(outer.read_bytes()).hexdigest()
        commit = "a" * 40
        record = {"name": "magpie-unsigned-3", "expired": False, "id": 87, "size_in_bytes": outer.stat().st_size,
                  "digest": "sha256:" + digest, "workflow_run": {"id": 65, "head_sha": commit}}
        metadata = self.base / "metadata.json"
        runner = self.base / "functions.sh"
        support = """set -eu
fail() { echo \"$*\" >&2; exit 1; }
gh() {
    case \"$1:$2\" in
        api:repos/fixture/repo/actions/artifacts/87) cat \"$META\" ;;
        api:repos/fixture/repo/actions/artifacts/87/zip) cat \"$ARCHIVE\" ;;
        *) exit 91 ;;
    esac
}
"""
        checks = ["valid_id", "valid_digest", "sha256"]
        # These small single-line definitions and the handoff body are the production code.
        lines = (ROOT / "scripts/ci/release-flow.sh").read_text().splitlines()
        helpers = [next(line for line in lines if line.startswith(name + "() ")) for name in checks]
        runner.write_text("\n".join([support, *helpers, self.flow_function("receive_artifact"), 'receive_artifact unsigned "$DEST"\n']))
        common = dict(os.environ, META=str(metadata), ARCHIVE=str(outer), repo="fixture/repo", work=str(self.base),
                      commit=commit, TOOLS=str(POLICY.parent), tag=self.version, ARTIFACT_ID="87", ARTIFACT_DIGEST=digest,
                      GITHUB_RUN_ID="65", GITHUB_RUN_ATTEMPT="3")
        for case, environment, ok in (("good", {}, True), ("previous-attempt", {"GITHUB_RUN_ATTEMPT": "4"}, False),
                                       ("different-run", {"GITHUB_RUN_ID": "66"}, False), ("different-commit", {"commit": "b" * 40}, False),
                                       ("changed-bytes", {}, False)):
            with self.subTest(case=case):
                metadata.write_text(json.dumps(record))
                if case == "changed-bytes":
                    new = self.base / "changed.zip"
                    with zipfile.ZipFile(new, "w") as z:
                        z.writestr("magpie-tile-unsigned.apk", b"different fixture")
                    environment = {"ARCHIVE": str(new)}
                dest = self.base / case
                r = subprocess.run(["sh", runner], env={**common, **environment, "DEST": str(dest)},
                                   capture_output=True, text=True, timeout=5)
                self.assertEqual(r.returncode == 0, ok, r.stdout + r.stderr)
                self.assertEqual(dest.is_dir(), ok)

    def test_immutable_repo_setting_is_checked_before_promoting_draft(self):
        support = """set -eu
fail() { echo \"$*\" >&2; exit 1; }
need() { [ -n \"$1\" ] || fail \"$2\"; }
gh() {
  [ \"$1:$2\" = api:repos/fixture/repo/immutable-releases ] || exit 91
  [ \"$GH_TOKEN\" = fixture-read-only-settings ] || exit 92
  printf '{\"enabled\":%s}\\n' \"$SETTING\"
}
"""
        script = support + self.flow_function("check_immutable_setting") + '\ncheck_immutable_setting\nprintf verified\n'
        for flag in ("false", "true"):
            result = subprocess.run(["sh", "-c", script],
                                    env=dict(os.environ, SETTING=flag, work=str(self.base), repo="fixture/repo",
                                             MAGPIE_RELEASE_SETTINGS_TOKEN="fixture-read-only-settings"),
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode == 0, flag == "true", result.stdout + result.stderr)
            if flag == "false":
                self.assertIn("draft left untouched", result.stderr)
            else:
                self.assertEqual(result.stdout, "verified")

    def test_mutable_release_cannot_reach_public_download_or_channel(self):
        (self.base / "release.json").write_text(json.dumps({"tag_name": "v1.2.7", "draft": False, "immutable": False}))
        support = 'set -eu\nfail() { echo "$*" >&2; exit 1; }\ncurl() { echo "unexpected download"; exit 90; }\n'
        script = support + self.flow_function("public_bytes") + '\npublic_bytes "$work"\n'
        result = subprocess.run(["sh", "-c", script], env=dict(os.environ, tag="v1.2.7", work=str(self.base)),
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not reported immutable", result.stderr)
        self.assertNotIn("unexpected download", result.stdout)

    def test_ref_gate_rejects_wrong_event_before_any_remote_operation(self):
        for mode, ref in (("build", "refs/heads/main"), ("recover", "refs/tags/v1.2.7"),
                          ("finalize", "refs/heads/not-main"), ("build", "refs/tags/v1.2.8")):
            with self.subTest(mode=mode, ref=ref):
                env = dict(os.environ, MODE=mode, TARGET_TAG="v1.2.7", GITHUB_REF=ref,
                           GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REPOSITORY="fixture/unused", RUNNER_TEMP=str(self.base))
                result = subprocess.run(["sh", str(ROOT / "scripts/ci/release-flow.sh"), "plan"], env=env,
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("new builds must run on the target tag ref", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
