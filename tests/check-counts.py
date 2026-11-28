"""Run each counted suite once; check the docs against that run, not cached counts."""
import argparse
from collections import Counter
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SHELL = ("install", "watchdog", "action", "service", "lib", "tile-check")
ASSERTION = re.compile(r"^  (PASS|FAIL|SKIP)(?=[ \t]|$)", re.MULTILINE)


class CheckError(Exception):
    pass


class FixtureFile(SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # The client suite already reports failed requests.


@contextmanager
def fixtures(work):
    directory = work / "fixtures"
    handler = partial(FixtureFile, directory=str(directory))
    # Keep the very same listening socket: never probe a free port and reopen it.
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        url = f"http://127.0.0.1:{server.server_port}"
        subprocess.run([sys.executable, str(HERE / "make-fixtures.py"), str(directory), "--base", url],
                       check=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield url
        finally:
            server.shutdown()
            thread.join()


def measure(script, work, verbose, **extra_env):
    # Some shell suites use /tmp before TMPDIR and delete TEST_BASE. Always supply
    # a distinct disposable TEST_BASE, never the run root or an inherited path.
    scratch = work / script
    scratch.mkdir()
    env = dict(os.environ, TMPDIR=str(scratch), TEST_BASE=str(scratch / "base"), **extra_env)
    log = scratch / "output.log"
    with log.open("wb") as out:
        rc = subprocess.run(["sh", str(HERE / script)], cwd=ROOT, env=env,
                            stdout=out, stderr=subprocess.STDOUT).returncode
    text = log.read_text(encoding="utf-8", errors="replace")
    counts = Counter(ASSERTION.findall(text))
    summary = f"{script}: exit={rc}, PASS={counts['PASS']}, SKIP={counts['SKIP']}, FAIL={counts['FAIL']}"
    if rc or counts["FAIL"] or not counts["PASS"]:
        print(text, end="", file=sys.stderr)
        raise CheckError(summary)
    if verbose:
        print(text, end="")
    print(summary, flush=True)
    return counts["PASS"] + counts["SKIP"], text


def check_docs(shell, jvm):
    total, jvm_total = sum(shell.values()), sum(jvm.values())
    parts = " + ".join(map(str, shell.values()))
    print(f"合计 {total} 条（{parts}），另有 {jvm_total} 条 JVM 用例")
    errors = []

    def require(path, text, pattern, expected):
        if not re.search(pattern, text, re.MULTILINE):
            errors.append(f"{path} 缺少 {expected}")

    for path in ("README.md", "README_EN.md", "tests/README.md"):
        text = (ROOT / path).read_text(encoding="utf-8")
        units = ("assertions total", "JVM cases") if path == "README_EN.md" else ("条断言", "条 JVM 用例")
        for n, unit in zip((total, jvm_total), units):
            require(path, text, rf"(?<![0-9]){n} {unit}", f"{n} {unit}")
        if path == "tests/README.md":
            for name, n in shell.items():
                require(path, text, rf"^\|\s*`test-{name}\.sh`\s*\|\s*{n}\s*\|", f"test-{name}.sh = {n}")
            for name, n in jvm.items():
                require(path, text, rf"`{re.escape(name)}`\s+{n}(?![0-9])", f"{name} = {n}")

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    version = next(line.split("=", 1)[1] for line in (ROOT / "module.prop").read_text().splitlines()
                   if line.startswith("version="))
    if re.search(r"^## 未发布(?:[ \t]|$)", changelog, re.M):
        version = "未发布"
    section = re.search(rf"^## {re.escape(version)}(?:[ \t]+[^\n]*)?$\n(.*?)(?=^## |\Z)",
                        changelog, re.M | re.S)
    if section is None:
        errors.append(f"CHANGELOG.md 缺少 {version} 一节")
    else:
        for n in (total, *shell.values()):
            require(f"CHANGELOG.md ({version})", section[1], rf"(?<![0-9]){n}(?![0-9])", str(n))
    if errors:
        raise CheckError("\n".join(errors))
    print("文档与实际一致。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verbose", action="store_true", help="也打印成功套件的逐项输出")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="magpie-counts.") as tmp:
        work = Path(tmp).resolve()
        shell = {}
        with fixtures(work) as url:
            for name in SHELL:
                env = {"TEST_SRV": url} if name in ("install", "action") else {}
                shell[name], _ = measure(f"test-{name}.sh", work, args.verbose, **env)
        n, log = measure("run-jvm.sh", work, args.verbose)
        # run-jvm is the authority on the set of classes; include FetchTest and
        # future suites without keeping a second hand-written class list here.
        jvm = {}
        for name, body in re.findall(r"^== jvm/(\w+)\n(.*?)(?=^== jvm/|\Z)", log, re.M | re.S):
            count = ASSERTION.findall(body).count("PASS")
            if not count or name in jvm:
                raise CheckError(f"无有效 PASS 或重复的 JVM 套件：{name}")
            jvm[name] = count
            print(f"  jvm/{name} {count}")
        if sum(jvm.values()) != n:
            raise CheckError("JVM 各套件 PASS 与实测总数不一致")
        check_docs(shell, jvm)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        sys.exit(128 + signum)  # unwind socket and private tempdir on TERM/HUP too

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        main()
    except (CheckError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
