#!/usr/bin/env python3
"""Fail-closed tile versionCode gate, comparing tracked runtime inputs in Git trees.

Runtime inputs are tile-app/src, tile-app/res and AndroidManifest.xml. README and
build tooling are intentionally excluded. Manifest versionCode/versionName alone
are version metadata, not payload changes. A missing explicit baseline is an error;
absence of any prior release tag is a valid first-release case.
"""
import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
RUNTIME_PATHS = ("tile-app/src", "tile-app/res", "tile-app/AndroidManifest.xml")
RELEASE_TAG = re.compile(r"v[0-9]{1,5}(?:\.[0-9]{1,5}){1,3}\Z")


class GateError(Exception):
    pass


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", str(repo), *args], text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode:
        detail = p.stderr.strip() or "git command failed"
        raise GateError(f"git {' '.join(args)}: {detail}")
    return p


def resolve_commit(repo, ref):
    p = git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}", check=False)
    if p.returncode:
        raise GateError(f"基线不可用或缺失：{ref}")
    return p.stdout.strip()


def manifest(repo, commit):
    p = git(repo, "show", f"{commit}:tile-app/AndroidManifest.xml", check=False)
    if p.returncode:
        raise GateError(f"提交 {commit[:12]} 缺少可读的 tile-app/AndroidManifest.xml")
    try:
        root = ET.fromstring(p.stdout)
    except ET.ParseError as exc:
        raise GateError(f"提交 {commit[:12]} 的磁贴 manifest XML 无效：{exc}") from exc
    raw = root.attrib.get(ANDROID + "versionCode", "")
    if not re.fullmatch(r"[0-9]+", raw):
        raise GateError(f"提交 {commit[:12]} 的 manifest versionCode 无效：{raw!r}")
    code = int(raw)
    if code < 1 or code > 2147483647:
        raise GateError(f"提交 {commit[:12]} 的 manifest versionCode 超出有效范围")
    # versionCode/versionName are deliberately ignored when deciding whether
    # shipped tile behavior/resources changed. Other manifest changes count.
    root.attrib.pop(ANDROID + "versionCode", None)
    root.attrib.pop(ANDROID + "versionName", None)
    for node in root.iter():
        node.attrib = dict(sorted(node.attrib.items()))
        if node.text is not None and not node.text.strip():
            node.text = None
        if node.tail is not None and not node.tail.strip():
            node.tail = None
    return code, ET.tostring(root, encoding="utf-8")


def tree_files(repo, commit):
    p = git(repo, "ls-tree", "-r", "--name-only", "-z", commit,
            "--", *RUNTIME_PATHS)
    return {name for name in p.stdout.split("\0") if name}


def payload_changed(repo, baseline, current):
    old_files = tree_files(repo, baseline)
    new_files = tree_files(repo, current)
    if old_files != new_files:
        return True
    for path in sorted(old_files):
        if path == "tile-app/AndroidManifest.xml":
            old = manifest(repo, baseline)[1]
            new = manifest(repo, current)[1]
        else:
            # Blob IDs are binary-safe (resources include PNGs), unlike decoding
            # arbitrary git-show output as UTF-8 text.
            old_p = git(repo, "rev-parse", "--verify", f"{baseline}:{path}", check=False)
            new_p = git(repo, "rev-parse", "--verify", f"{current}:{path}", check=False)
            if old_p.returncode or new_p.returncode:
                raise GateError(f"无法比较运行时文件：{path}")
            old, new = old_p.stdout, new_p.stdout
        if old != new:
            return True
    return False


def latest_prior_tag(repo, current_tag, current_commit):
    # Only release-shaped tags reachable from the target commit are candidates.
    # Exclude the tag being published by name; a different release tag on the
    # same commit is still a valid prior baseline, and is vital for CI reruns.
    tags = git(repo, "tag", "--merged", current_commit, "--list", "v*",
               "--sort=-version:refname").stdout.splitlines()
    for tag in tags:
        if not RELEASE_TAG.fullmatch(tag) or tag == current_tag:
            continue
        commit = resolve_commit(repo, f"refs/tags/{tag}")
        return tag, commit
    return None, None


def check(repo, base_ref=None, current_tag=None):
    shallow = git(repo, "rev-parse", "--is-shallow-repository").stdout.strip()
    if shallow == "true":
        raise GateError("仓库是 shallow checkout；必须先取完整历史/基线，不能跳过版本门槛")
    current = resolve_commit(repo, "HEAD")
    if base_ref and current_tag:
        raise GateError("--base-ref 与 --current-tag 不能同时使用")
    if current_tag:
        tag_commit = resolve_commit(repo, f"refs/tags/{current_tag}")
        if tag_commit != current:
            raise GateError(f"当前 tag {current_tag} 不指向待检查的 HEAD")
        label, baseline = latest_prior_tag(repo, current_tag, current)
        if baseline is None:
            print(f"PASS：{current_tag} 没有可用的前序发布 tag，作为首次发布检查")
            return
    elif base_ref:
        label = base_ref
        baseline = resolve_commit(repo, base_ref)
    else:
        label, baseline = latest_prior_tag(repo, None, current)
        if baseline is None:
            print("PASS：仓库没有前序发布 tag，作为首次发布检查")
            return

    old_code, _ = manifest(repo, baseline)
    new_code, _ = manifest(repo, current)
    changed = payload_changed(repo, baseline, current)
    if changed and new_code <= old_code:
        raise GateError(
            f"磁贴运行时代码/资源/manifest 有变化，versionCode 必须高于基线 "
            f"{label}={old_code}（当前={new_code}）"
        )
    if changed:
        print(f"PASS：运行时内容变化，versionCode {old_code} → {new_code}（基线 {label}）")
    else:
        print(f"PASS：运行时内容未变（基线 {label}，versionCode {old_code} → {new_code}）")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Git 工作树（默认当前目录）")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--base-ref", help="可信 CI 基线分支/提交/tag")
    group.add_argument("--current-tag", help="待发布 tag；自动排除它并选择前序 tag")
    args = parser.parse_args()
    try:
        check(args.repo, args.base_ref, args.current_tag)
    except GateError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
