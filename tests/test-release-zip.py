#!/usr/bin/env python3
"""Offline release-verifier / tile-build regressions; no real APK, key or service.

The Android tools are deterministic fakes. These tests exercise fail-closed
orchestration and parsing, not Android's cryptographic implementation. Counts
are independent of check-counts.sh's original five shell suites.
"""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CERT = "A1" * 32
OTHER_CERT = "B2" * 32
MANIFEST = """<manifest xmlns:android="http://schemas.android.com/apk/res/android"
package="com.ruin.magpie.tile" android:versionCode="9">
<uses-sdk android:minSdkVersion="29" android:targetSdkVersion="37"/>
</manifest>
"""
BADGING = """package: name='com.ruin.magpie.tile' versionCode='9' versionName='1.2.5'
sdkVersion:'29'
targetSdkVersion:'37'
"""
REQUIRED = (
    "service.sh", "action.sh", "uninstall.sh", "customize.sh",
    "scripts/magpie.service", "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
)


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class ReleaseVerifierTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="magpie-verifier-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "historical source"
        (self.source / "tile-app").mkdir(parents=True)
        self.manifest = self.source / "tile-app/AndroidManifest.xml"
        self.manifest.write_text(MANIFEST)
        # Tool is intentionally NOT under SOURCE_ROOT and has no colocated cert.
        self.script = self.base / "runner temp tools/verify-release-zip.sh"
        self.script.parent.mkdir()
        shutil.copyfile(ROOT / "scripts/ci/verify-release-zip.sh", self.script)
        self.cert_file = self.base / "trusted-cert.txt"
        self.cert_file.write_text("# trusted public test fingerprint\n" + CERT + "\n")
        self.bin = self.base / "bin"
        executable(self.bin / "apksigner", """#!/bin/sh
cat "$MOCK_CERT_OUTPUT"
exit "${MOCK_VERIFY_RC:-0}"
""")
        executable(self.bin / "aapt", """#!/bin/sh
cat "$MOCK_BADGING"
exit "${MOCK_AAPT_RC:-0}"
""")
        self.cert_output = self.base / "cert-output.txt"
        self.cert_output.write_text("Signer #1 certificate SHA-256 digest: " + CERT.lower() + "\n")
        self.badging = self.base / "badging.txt"
        self.badging.write_text(BADGING)
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + self.env["PATH"],
            "SOURCE_ROOT": str(self.source),
            "EXPECTED_CERT_FILE": str(self.cert_file),
            "MOCK_CERT_OUTPUT": str(self.cert_output),
            "MOCK_BADGING": str(self.badging),
            "MOCK_VERIFY_RC": "0", "MOCK_AAPT_RC": "0",
            "TMPDIR": str(self.base),
        })
        self.archive = self.base / "release archive.zip"
        self.make_zip()

    def make_zip(self, props="id=magpie\nversion=v1.2.5\nversionCode=1107\n",
                 tile="9\n", omit=(), extra=()):
        entries = [(name, b"fixture\n") for name in REQUIRED]
        entries += [("module.prop", props), ("magpie-tile.apk", b"fake APK"), ("tile-version", tile)]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)  # Intentionally duplicate ZIP entries.
            with zipfile.ZipFile(self.archive, "w") as archive:
                for name, value in entries:
                    if name not in omit:
                        archive.writestr(name, value)
                for name, value in extra:
                    archive.writestr(name, value)

    def run_verifier(self, success=True, message=None, tag="v1.2.5", relative=False, extra_args=()):
        path = self.archive.name if relative else str(self.archive)
        result = subprocess.run(
            ["sh", str(self.script), path, tag, *extra_args],
            cwd=self.base, env=self.env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=15,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        if message:
            self.assertIn(message, result.stdout)
        # All exits, including malformed archives, must clean their mktemp workspace.
        self.assertFalse(list(self.base.glob("tmp.*")), result.stdout)
        return result

    def test_valid_relocated_tool_and_relative_zip(self):
        self.run_verifier(relative=True, message="全部通过")

    def test_current_directory_is_source_fallback(self):
        del self.env["SOURCE_ROOT"]
        self.archive = self.source / "release.zip"
        self.make_zip()
        result = subprocess.run(["sh", str(self.script), "release.zip", "v1.2.5"],
                                cwd=self.source, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_explicit_source_metadata_not_tool_checkout(self):
        self.manifest.write_text(MANIFEST.replace('versionCode="9"', 'versionCode="10"'))
        self.run_verifier(False, "versionCode")

    def test_source_root_cannot_be_empty(self):
        self.env["SOURCE_ROOT"] = ""
        self.run_verifier(False, "SOURCE_ROOT")

    def test_cert_path_must_be_absolute(self):
        self.env["EXPECTED_CERT_FILE"] = self.cert_file.name
        self.run_verifier(False, "绝对路径")

    def test_cert_file_requires_single_64_hex_digest(self):
        for value in ("", "not-a-digest", "G" * 64, "A" * 63, "A" * 65,
                      CERT + "\n" + CERT, CERT + "\n" + OTHER_CERT, "A1:" * 31 + "A1"):
            with self.subTest(value=value):
                self.cert_file.write_text(value + "\n")
                self.run_verifier(False, "64 个十六进制")

    def test_verify_nonzero_even_with_matching_digest(self):
        self.env["MOCK_VERIFY_RC"] = "42"
        self.run_verifier(False, "apksigner verify 失败")

    def test_verify_output_missing_or_malformed_digest(self):
        for value in ("", "Signer #1 public key SHA-256 digest: " + CERT,
                      "Signer #1 certificate SHA-256 digest: bad",
                      "Signer #1 certificate SHA-256 digest: " + CERT + ":"):
            with self.subTest(value=value):
                self.cert_output.write_text(value + "\n")
                self.run_verifier(False)

    def test_unexpected_signer_is_rejected_in_any_order(self):
        for digests in ((CERT, OTHER_CERT), (OTHER_CERT, CERT), (OTHER_CERT,)):
            with self.subTest(digests=digests):
                self.cert_output.write_text("".join(
                    f"Signer #{i} certificate SHA-256 digest: {digest}\n"
                    for i, digest in enumerate(digests, 1)))
                self.run_verifier(False, "非预期签名证书")

    def test_repeated_expected_cert_across_schemes_is_allowed(self):
        self.cert_output.write_text(
            "Signer #1 certificate SHA-256 digest: " + CERT.lower() + "\n"
            "V3.0 Signer: certificate SHA-256 digest: " + CERT + "\n")
        self.run_verifier()

    def test_zip_version_must_equal_nonempty_tag(self):
        self.run_verifier(False, "!= tag", tag="v1.2.4")
        self.run_verifier(False, "tag 不能为空", tag="")

    def test_extra_arguments_are_rejected(self):
        self.run_verifier(False, "用法", extra_args=("extra",))

    def test_duplicate_module_metadata_is_rejected(self):
        for line in ("version=v1.2.5", "version=v0.0.0", "versionCode=1107", "id=magpie"):
            with self.subTest(line=line):
                self.make_zip(props="id=magpie\nversion=v1.2.5\nversionCode=1107\n" + line + "\n")
                self.run_verifier(False, "重复")

    def test_missing_or_invalid_module_metadata_is_rejected(self):
        for props in ("version=v1.2.5\n", "version=v1.2.5\nversionCode=1x\n",
                      "versionCode=1107\n", "version =v1.2.5\nversionCode=1107\n"):
            with self.subTest(props=props):
                self.make_zip(props=props)
                self.run_verifier(False)

    def test_tile_version_is_one_numeric_line_matching_apk(self):
        for tile in ("", "9\n9\n", "9\n\n", "9x\n", "8\n"):
            with self.subTest(tile=tile):
                self.make_zip(tile=tile)
                self.run_verifier(False, "tile-version")

    def test_historical_no_apk_release_is_explicitly_unsupported(self):
        self.make_zip(props="id=magpie\nversion=v1.2.4\nversionCode=1106\n",
                      omit=("magpie-tile.apk", "tile-version"))
        # The hard gate must fire even when the old source has no tile manifest.
        self.manifest.unlink()
        self.run_verifier(False, "历史无 APK", tag="v1.2.4")

    def test_missing_required_files_or_tile_pair_is_rejected(self):
        for name in (*REQUIRED, "module.prop", "magpie-tile.apk", "tile-version"):
            with self.subTest(name=name):
                self.make_zip(omit=(name,))
                self.run_verifier(False)

    def test_bad_zip_and_corrupt_crc_are_rejected(self):
        self.archive.write_bytes(b"not a ZIP")
        self.run_verifier(False)
        self.make_zip()
        data = self.archive.read_bytes()
        self.assertIn(b"fake APK", data)
        self.archive.write_bytes(data.replace(b"fake APK", b"fake APX", 1))
        self.run_verifier(False)

    def test_duplicate_files_and_directories_are_rejected(self):
        for extra in ((("module.prop", "version=v1.2.5\n"),),
                      (("scripts/", b""), ("scripts/", b"")),
                      (("clash", b"x"), ("clash/", b"")),
                      (("parent", b"x"), ("parent/child", b"x"))):
            with self.subTest(extra=extra):
                self.make_zip(extra=extra)
                self.run_verifier(False)

    def test_unsafe_zip_paths_and_characters_are_rejected(self):
        for name in ("/absolute", "../escape", "a/../escape", "a/./b", "a//b",
                     "C:/windows", "a\\b", "line\nbreak", "carriage\rreturn", "tab\tname",
                     "a\x7fb", "a\u202eb", "a b", "a;b", "$(touch bad)", "a`id`", "a|b"):
            with self.subTest(name=name):
                self.make_zip(extra=((name, b"x"),))
                self.run_verifier(False)

    def test_nul_in_zip_name_is_not_hidden_by_zipfile(self):
        self.make_zip(extra=(("evilXname", b"x"),))
        self.archive.write_bytes(self.archive.read_bytes().replace(b"evilXname", b"evil\0name"))
        self.run_verifier(False, "危险字符")

    def test_symlinks_and_special_files_are_rejected(self):
        for mode in (stat.S_IFLNK, stat.S_IFIFO, stat.S_IFCHR):
            with self.subTest(mode=mode):
                info = zipfile.ZipInfo("unsafe")
                info.create_system = 3
                info.external_attr = (mode | 0o777) << 16
                self.make_zip(extra=((info, b"target"),))
                self.run_verifier(False, "symlink 或特殊文件")

    def test_repository_files_are_rejected(self):
        self.make_zip(extra=(("README.md", "not a module file"),))
        self.run_verifier(False, "仓库文件")

    def test_aapt_nonzero_even_with_valid_badging(self):
        self.env["MOCK_AAPT_RC"] = "7"
        self.run_verifier(False, "aapt dump badging 失败")

    def test_apk_metadata_mismatch_is_rejected(self):
        for before, after in (("com.ruin.magpie.tile", "com.attacker.tile"),
                              ("versionCode='9'", "versionCode='8'"),
                              ("sdkVersion:'29'", "sdkVersion:'28'"),
                              ("targetSdkVersion:'37'", "targetSdkVersion:'36'")):
            with self.subTest(before=before):
                self.badging.write_text(BADGING.replace(before, after))
                self.run_verifier(False, "!= 源码")

    def test_missing_and_duplicate_apk_metadata_are_rejected(self):
        for line in BADGING.splitlines():
            for bad in (BADGING + line + "\n", BADGING.replace(line + "\n", "")):
                with self.subTest(bad=bad):
                    self.badging.write_text(bad)
                    self.run_verifier(False, "必须恰好一行")
        for field in ("name='com.ruin.magpie.tile'", "versionCode='9'"):
            self.badging.write_text(BADGING.replace(field, field + " " + field))
            self.run_verifier(False, "缺失或重复")

    def test_source_manifest_must_have_unique_metadata(self):
        for bad in (MANIFEST.replace("<uses-sdk", '<uses-sdk android:minSdkVersion="29"/><uses-sdk'),
                    MANIFEST.replace('versionCode="9"', 'versionCode="9" android:versionCode="9"'),
                    MANIFEST.replace('android:targetSdkVersion="37"', "")):
            with self.subTest(bad=bad):
                self.manifest.write_text(bad)
                self.run_verifier(False)


class TileBuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="magpie-tile-build-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.tile = self.base / "tile-app"
        self.tile.mkdir()
        shutil.copyfile(ROOT / "tile-app/build.sh", self.tile / "build.sh")
        (self.tile / "AndroidManifest.xml").write_text(MANIFEST)
        (self.tile / "res").mkdir()
        src = self.tile / "src/com/ruin/magpie/tile"
        src.mkdir(parents=True)
        for name in ("MagpieTileService", "MainActivity", "LauncherIcon", "Shell"):
            (src / (name + ".java")).write_text("// fixture, not real Android source\n")
        self.bin = self.base / "bin"
        self.sdk = self.base / "sdk"
        bt = self.sdk / "build-tools/34.0.0"
        jar = self.sdk / "platforms/android-34/android.jar"
        jar.parent.mkdir(parents=True)
        jar.write_bytes(b"fake SDK")
        # One Python fake drives all tool stages and never reads a keystore.
        fake = "#!" + sys.executable + "\n" + r'''
import json
import os
from pathlib import Path
import shutil
import sys
import zipfile
name = Path(sys.argv[0]).name
args = sys.argv[1:]
def arg(flag):
    return args[args.index(flag) + 1]
if name == "aapt":
    if "-J" in args and os.environ.get("MOCK_NO_R") != "1":
        p = Path(arg("-J")) / "com/ruin/magpie/tile/R.java"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("// generated R fixture\n")
    if "-F" in args:
        with zipfile.ZipFile(arg("-F"), "w") as z:
            z.writestr("AndroidManifest.xml", b"fixture")
elif name == "javac":
    if os.environ.get("MOCK_JAVAC_RC"):
        sys.exit(int(os.environ["MOCK_JAVAC_RC"]))
    for source in (p for p in args if p.endswith(".java")):
        p = Path(arg("-d")) / "com/ruin/magpie/tile" / (Path(source).stem + ".class")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"fake class")
elif name == "d8":
    if os.environ.get("MOCK_D8_RC"):
        sys.exit(int(os.environ["MOCK_D8_RC"]))
    (Path(arg("--output")) / "classes.dex").write_bytes(b"MagpieTileService MainActivity LauncherIcon Shell SelfCheck TileState SerialExecutor")
elif name == "zipalign":
    shutil.copyfile(args[-2], args[-1])
elif name == "apksigner":
    with open(os.environ["MOCK_SIGN_CALLS"], "a") as f:
        f.write(json.dumps(args) + "\n")
    if args[0] == "sign":
        # Leave an artifact even on failure: a following successful verify must
        # never turn that failed sign into a successful build.
        shutil.copyfile(args[-1], arg("--out"))
        sys.exit(int(os.environ.get("MOCK_SIGN_RC", "0")))
    sys.exit(int(os.environ.get("MOCK_BUILD_VERIFY_RC", "0")))
'''
        for name, directory in (("aapt", self.bin), ("javac", self.bin),
                                ("zipalign", self.bin), ("d8", bt), ("apksigner", bt)):
            executable(directory / name, fake)
        self.calls = self.base / "sign-calls.jsonl"
        self.env = os.environ.copy()
        # Only synthetic fixtures: no real signing material is accessed.
        fake_key = self.base / "NOT-A-REAL-KEY.fixture"
        fake_key.write_text("not a keystore; mock apksigner never opens this file\n")
        self.fake_password = "test-only-password-never-in-argv"
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + self.env["PATH"],
            "ANDROID_SDK": str(self.sdk), "ANDROID_JAR": str(jar),
            "MAGPIE_KEYSTORE": str(fake_key), "MAGPIE_KS_PASS": self.fake_password,
            "MOCK_SIGN_CALLS": str(self.calls),
        })
        for key in ("MOCK_NO_R", "MOCK_JAVAC_RC", "MOCK_D8_RC", "MOCK_SIGN_RC", "MOCK_BUILD_VERIFY_RC"):
            self.env.pop(key, None)

    def run_build(self, success=True, message=None, mode=None):
        result = subprocess.run(["sh", str(self.tile / "build.sh"), *([mode] if mode else []), str(self.base / "out")],
                                cwd=self.base, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout)
        if message:
            self.assertIn(message, result.stdout)
        self.assertNotIn(self.fake_password, result.stdout)
        return result

    def test_unsigned_build_has_no_signing_calls_or_key_requirement(self):
        self.env.pop("MAGPIE_KEYSTORE")
        self.env.pop("MAGPIE_KS_PASS")
        self.run_build(mode="--unsigned")
        self.assertFalse(self.calls.exists())
        self.assertTrue((self.base / "out/magpie-tile-unsigned.apk").is_file())
        self.assertFalse((self.base / "out/magpie-tile.apk").exists())

    def test_sign_uses_environment_references_not_password_arguments(self):
        self.run_build()
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], ["sign", "verify"])
        for flag in ("--ks-pass", "--key-pass"):
            self.assertEqual(calls[0][calls[0].index(flag) + 1], "env:MAGPIE_KS_PASS")
        self.assertNotIn(self.fake_password, self.calls.read_text())
        self.assertTrue((self.base / "out/magpie-tile.apk").is_file())
        self.assertFalse(list((self.base / "out").glob(".tile-build.*")))

    def test_sign_nonzero_with_artifact_does_not_reach_verify(self):
        self.env["MOCK_SIGN_RC"] = "42"
        self.run_build(False, "apksigner sign 退出码 42")
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], ["sign"])

    def test_missing_r_java_is_rejected(self):
        self.env["MOCK_NO_R"] = "1"
        self.run_build(False, "R.java")
        self.assertFalse(self.calls.exists())

    def test_javac_failure_is_reported_independently(self):
        self.env["MOCK_JAVAC_RC"] = "11"
        self.run_build(False, "javac 退出码 11")
        self.assertFalse(self.calls.exists())

    def test_dex_failure_is_reported_independently(self):
        self.env["MOCK_D8_RC"] = "12"
        self.run_build(False, "d8 退出码 12")
        self.assertFalse(self.calls.exists())

    def test_final_signature_verification_remains_mandatory(self):
        self.env["MOCK_BUILD_VERIFY_RC"] = "1"
        self.run_build(False, "签名校验失败")


if __name__ == "__main__":
    unittest.main(verbosity=2)
