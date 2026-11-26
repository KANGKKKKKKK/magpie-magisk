#!/usr/bin/env python3
"""Offline tests of the actual doctor.sh tile section, not a copied decision tree.

Only the uniquely anchored [9/10] section is executed. tile-check.sh and the
ok/warn/bad reporters are sandbox fixtures; all other doctor sections are excluded.
The child PATH contains only sh/cat/grep/sed/tail, with no device or network tools.
Run directly with: python3 tests/test-doctor-tile.py
"""
from collections import namedtuple
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOCTOR = ROOT / "scripts/doctor.sh"
START = 'echo "[9/10] 磁贴（可选组件）"'
END = 'echo "[10/10] 日志与磁盘"'
FINISHED = "__DOCTOR_TILE_TEST_FINISHED__"
Report = namedtuple("Report", "level message detail")
HEALTHY = {
    "mod": "1", "svc": "running", "installed": "1", "uid": "10123",
    "vcode": "11", "magisk": "2", "inqs": "1", "painted": "运行中",
    "alive": "2", "frozen": "0", "freezer": "", "done": "1",
}


def extract_tile_section(source):
    """Fail closed if either whole-line anchor is missing, repeated or reversed."""
    lines = source.splitlines()
    for anchor in (START, END):
        if lines.count(anchor) != 1:
            raise ValueError("doctor tile anchor must occur exactly once: " + anchor)
    first, last = lines.index(START), lines.index(END)
    if first >= last:
        raise ValueError("doctor tile anchors are reversed")
    section = "\n".join(lines[first:last]) + "\n"
    # Also verify the extracted block still calls the fixture target exactly once
    # and contains the real parser. Never fall back to running the entire doctor.
    for required in ('_tc_sh="$MODDIR/scripts/tile-check.sh"', "tcget() {"):
        if section.count(required) != 1:
            raise ValueError("unexpected doctor tile section: " + required)
    if section.rstrip().splitlines()[-1] != "fi":
        raise ValueError("doctor tile section has an unexpected end")
    for forbidden in ("http_codes", "http_code(", "WEB_KEY=", "gateway-key ",
                      'touch "$magpie_path', "[8/10]", "[10/10]"):
        if forbidden in section:
            raise ValueError("non-tile doctor code crossed the anchors: " + forbidden)
    return section


def payload(values):
    return "".join(f"{key}={value}\n" for key, value in values.items())


class ExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = DOCTOR.read_text(encoding="utf-8")

    def test_extracts_only_actual_tile_section(self):
        section = extract_tile_section(self.source)
        self.assertTrue(section.startswith(START + "\n"))
        self.assertTrue(section.rstrip().endswith("\nfi"))
        self.assertIn('_tc=$(sh "$_tc_sh" 2>/dev/null)', section)
        for outside in (END, "[8/10]", "WEB_KEY=", "gateway-key ", "http_codes",
                        'touch "$magpie_path', "数据目录可写"):
            self.assertNotIn(outside, section)

    def test_rejects_each_missing_anchor(self):
        for anchor in (START, END):
            with self.subTest(anchor=anchor):
                with self.assertRaisesRegex(ValueError, "exactly once"):
                    extract_tile_section(self.source.replace(anchor + "\n", "", 1))

    def test_rejects_each_duplicate_anchor(self):
        for anchor in (START, END):
            with self.subTest(anchor=anchor):
                with self.assertRaisesRegex(ValueError, "exactly once"):
                    extract_tile_section(self.source + "\n" + anchor + "\n")

    def test_rejects_reversed_anchors(self):
        reversed_source = self.source.replace(START, "__SWAP_TILE_ANCHOR__", 1)
        reversed_source = reversed_source.replace(END, START, 1)
        reversed_source = reversed_source.replace("__SWAP_TILE_ANCHOR__", END, 1)
        with self.assertRaisesRegex(ValueError, "reversed"):
            extract_tile_section(reversed_source)


class DoctorTileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.section = extract_tile_section(DOCTOR.read_text(encoding="utf-8"))
        cls.commands = {}
        for name in ("sh", "cat", "grep", "sed", "tail"):
            path = shutil.which(name, path=os.defpath)
            if path is None:
                raise RuntimeError("required POSIX test command is missing: " + name)
            cls.commands[name] = path

    def run_tile(self, values=None, *, raw=None, status=0, script_exists=True,
                 **changes):
        values = dict(HEALTHY if values is None else values)
        values.update(changes)
        if raw is None:
            raw = payload(values)
        with tempfile.TemporaryDirectory(prefix="magpie-doctor-tile-") as directory:
            sandbox = Path(directory)
            scripts = sandbox / "module/scripts"
            scripts.mkdir(parents=True)
            bindir = sandbox / "bin"
            bindir.mkdir()
            for name, path in self.commands.items():
                (bindir / name).symlink_to(path)
            output = sandbox / "tile-output.txt"
            output.write_text(raw, encoding="utf-8")
            calls = sandbox / "tile-calls.txt"
            if script_exists:
                (scripts / "tile-check.sh").write_text(
                    '#!/bin/sh\n'
                    'printf "called\\n" >> "$TILE_CALL_LOG"\n'
                    'cat "$TILE_OUTPUT"\n'
                    'exit "$TILE_EXIT"\n', encoding="utf-8")
            harness = r'''
ok()   { printf 'REPORT\tok\t%s\t%s\n' "$1" "${2-}"; }
warn() { printf 'REPORT\twarn\t%s\t%s\n' "$1" "${2-}"; }
bad()  { printf 'REPORT\tbad\t%s\t%s\n' "$1" "${2-}"; }
'''
            harness += self.section + "\nprintf '%s\\n' '" + FINISHED + "'\n"
            result = subprocess.run(
                [self.commands["sh"]], input=harness, text=True, encoding="utf-8",
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
                cwd=sandbox, env={
                    "PATH": str(bindir), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
                    "HOME": str(sandbox), "TMPDIR": str(sandbox),
                    "MODDIR": str(scripts.parent), "TILE_OUTPUT": str(output),
                    "TILE_CALL_LOG": str(calls), "TILE_EXIT": str(status),
                })
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "", result.stderr)
            self.assertEqual(calls.read_text(encoding="utf-8") if calls.exists()
                             else "", "called\n" if script_exists else "")
            lines = result.stdout.splitlines()
            self.assertGreaterEqual(len(lines), 2, result.stdout)
            self.assertEqual(lines[0], "[9/10] 磁贴（可选组件）")
            self.assertEqual(lines[-1], FINISHED, result.stdout)
            reports = []
            for line in lines[1:-1]:
                fields = line.split("\t", 3)
                self.assertEqual(len(fields), 4, line)
                self.assertEqual(fields[0], "REPORT", line)
                self.assertIn(fields[1], ("ok", "warn", "bad"), line)
                reports.append(Report(*fields[1:]))
            return reports

    def assert_report(self, reports, level, phrase):
        self.assertTrue(any(item.level == level and phrase in item.message
                            for item in reports), repr(reports))

    def assert_no_report(self, reports, phrase, level=None):
        self.assertFalse(any(phrase in item.message and
                             (level is None or item.level == level)
                             for item in reports), repr(reports))

    def assert_incomplete(self, reports):
        self.assertEqual(len(reports), 1, repr(reports))
        self.assert_report(reports, "warn", "磁贴检查未完成，本次结果未知")
        self.assertFalse(any(item.level == "ok" for item in reports))

    def assert_count_unknown(self, reports):
        self.assert_report(reports, "warn", "进程或冻结状态未知")
        for false_conclusion in ("进程未被冻结", "进程当前未运行", "进程被冻结（"):
            self.assert_no_report(reports, false_conclusion)

    def test_command_failure_rejects_even_complete_healthy_output(self):
        self.assert_incomplete(self.run_tile(status=7))

    def test_missing_tile_check_script_reports_incomplete(self):
        self.assert_incomplete(self.run_tile(script_exists=False))

    def test_missing_done_reports_incomplete(self):
        values = dict(HEALTHY)
        values.pop("done")
        self.assert_incomplete(self.run_tile(values))

    def test_invalid_or_nonfinal_done_reports_incomplete(self):
        for raw in (payload(dict(HEALTHY, done="0")),
                    payload(dict(HEALTHY, done="unknown")),
                    payload(HEALTHY) + "trailing=1\n"):
            with self.subTest(raw=raw):
                self.assert_incomplete(self.run_tile(raw=raw))

    def test_duplicate_fields_never_select_a_convenient_value(self):
        for key, value in HEALTHY.items():
            for repeated_value in (value, "unknown" if value != "unknown" else "0"):
                with self.subTest(key=key, repeated_value=repeated_value):
                    duplicate = f"{key}={repeated_value}\n"
                    raw = payload(HEALTHY).replace("done=1\n", duplicate + "done=1\n")
                    self.assert_incomplete(self.run_tile(raw=raw))

    def test_missing_required_fields_never_report_healthy(self):
        for key in HEALTHY:
            if key == "done":
                continue
            with self.subTest(key=key):
                values = dict(HEALTHY)
                values.pop(key)
                self.assert_incomplete(self.run_tile(values))

    def test_installed_unknown_never_means_not_installed(self):
        reports = self.run_tile(installed="unknown")
        self.assert_report(reports, "warn", "磁贴 App 安装状态未知")
        self.assert_no_report(reports, "未安装磁贴 App")
        self.assert_no_report(reports, "已安装磁贴 App")
        self.assertEqual([item.level for item in reports], ["warn"])

    def test_service_unknown_with_stopped_paint_is_not_confirmed_stopped(self):
        reports = self.run_tile(svc="unknown", painted="已停止")
        self.assert_report(reports, "warn", "服务状态未知，无法确认")
        self.assert_no_report(reports, "已停止", level="ok")
        self.assert_no_report(reports, "实际是「已停止」")
        self.assert_no_report(reports, "实际是「运行中」")

    def test_alive_unknown_with_zero_frozen_is_not_unfrozen(self):
        self.assert_count_unknown(self.run_tile(alive="unknown", frozen="0"))

    def test_frozen_unknown_with_alive_processes_is_not_unfrozen(self):
        self.assert_count_unknown(self.run_tile(alive="2", frozen="unknown"))

    def test_both_counts_unknown_are_not_zero(self):
        self.assert_count_unknown(self.run_tile(alive="unknown", frozen="unknown"))

    def test_invalid_alive_counts_do_not_imply_unfrozen_or_dead(self):
        for value in ("", "-1", "+1", "1.5", "NaN", "2 processes"):
            with self.subTest(alive=value):
                self.assert_count_unknown(self.run_tile(alive=value, frozen="0"))

    def test_invalid_frozen_counts_do_not_imply_unfrozen(self):
        for value in ("", "-1", "+1", "0.5", "NaN", "0 processes"):
            with self.subTest(frozen=value):
                self.assert_count_unknown(self.run_tile(alive="2", frozen=value))

    def test_frozen_greater_than_alive_is_unknown_not_a_freeze_conclusion(self):
        reports = self.run_tile(alive="1", frozen="2")
        self.assert_report(reports, "warn", "进程与冻结计数不一致，本次冻结状态未知")
        self.assert_no_report(reports, "进程未被冻结")
        self.assert_no_report(reports, "进程被冻结（")

    def test_confirmed_optional_not_installed_is_not_an_error(self):
        reports = self.run_tile({"mod": "1", "svc": "running",
                                 "installed": "0", "done": "1"})
        self.assertEqual(len(reports), 1, repr(reports))
        self.assert_report(reports, "ok", "未安装磁贴 App（可选组件，不影响网关）")

    def test_complete_healthy_install_reports_only_confirmed_success(self):
        reports = self.run_tile()
        self.assertEqual([item.level for item in reports], ["ok"] * 4)
        for phrase in ("已安装磁贴 App", "Magisk 里已允许 root",
                       "磁贴显示「运行中」，与实际一致", "进程未被冻结（2 个进程全部可运行）"):
            self.assert_report(reports, "ok", phrase)

    def test_confirmed_stopped_service_is_a_valid_control_case(self):
        reports = self.run_tile(svc="stopped", painted="已停止")
        self.assert_report(reports, "ok", "磁贴显示「已停止」，与实际一致")
        self.assert_no_report(reports, "服务状态未知")

    def test_confirmed_frozen_processes_are_a_valid_control_case(self):
        reports = self.run_tile(alive="2", frozen="1", freezer="NoActive")
        self.assert_report(reports, "warn", "进程被冻结（1/2 个）")
        self.assert_no_report(reports, "进程未被冻结")

    def test_confirmed_zero_alive_is_distinct_from_unknown(self):
        reports = self.run_tile(alive="0", frozen="0")
        self.assert_report(reports, "ok", "进程当前未运行")
        self.assert_no_report(reports, "进程未被冻结")
        self.assert_no_report(reports, "进程或冻结状态未知")

    def test_root_unknown_never_means_allowed_denied_or_unrequested(self):
        reports = self.run_tile(magisk="unknown")
        self.assert_report(reports, "warn", "root 授权状态未知")
        for phrase in ("Magisk 里已允许 root", "Magisk 里 root 被拒绝",
                       "Magisk 里 root 尚未授权"):
            self.assert_no_report(reports, phrase)

    def test_module_unknown_never_means_module_not_installed(self):
        reports = self.run_tile(mod="unknown")
        self.assert_report(reports, "warn", "模块安装状态未知")
        self.assert_no_report(reports, "没找到 magpie 模块")


if __name__ == "__main__":
    unittest.main(verbosity=2)
