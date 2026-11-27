#!/usr/bin/env python3
"""Build/verify exact release payloads and unwrap bounded Actions artifacts as data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile


PAYLOAD = {
    "LICENSE": 0o644,
    "module.prop": 0o644,
    "META-INF/com/google/android/update-binary": 0o644,
    "META-INF/com/google/android/updater-script": 0o644,
    "action.sh": 0o755,
    "customize.sh": 0o755,
    "service.sh": 0o755,
    "uninstall.sh": 0o755,
    "scripts/doctor.sh": 0o755,
    "scripts/install.sh": 0o755,
    "scripts/lib.sh": 0o755,
    "scripts/magpie-cli.sh": 0o755,
    "scripts/magpie.config": 0o644,
    "scripts/magpie.service": 0o755,
    "scripts/status.sh": 0o755,
    "scripts/tile-app.sh": 0o644,
    "scripts/tile-check.sh": 0o755,
    "system/bin/magpie": 0o755,
    "system/etc/resolv.conf": 0o644,
    "webroot/index.html": 0o644,
}
# The body is never inside the module. These are upper limits, not expected sizes.
MAX_APK = 4 * 1024 * 1024
MAX_MODULE = 8 * 1024 * 1024
MAX_SOURCE = 512 * 1024
TAG = re.compile(r"v[0-9]{1,9}\.[0-9]{1,9}(?:\.[0-9]{1,9})?(?:-[0-9A-Za-z][0-9A-Za-z.-]{0,60})?\Z", re.ASCII)
SHA = re.compile(r"[0-9a-f]{40}\Z", re.ASCII)
APK = "magpie-tile.apk"
UNSIGNED = "magpie-tile-unsigned.apk"


def source_bytes(root, ref, name):
    if ref:
        if not SHA.fullmatch(ref):
            raise ValueError("need an exact commit SHA")
        # Do not check out or execute the candidate. Require a regular tracked blob.
        entry = subprocess.check_output(["git", "-C", root, "ls-tree", ref, "--", name])
        if not re.match(rb"100(?:644|755) blob [0-9a-f]+\t", entry):
            raise ValueError(f"missing/non-regular Git blob: {name}")
        spec = f"{ref}:{name}"
        size = int(subprocess.check_output(["git", "-C", root, "cat-file", "-s", spec]))
        if not 0 < size <= MAX_SOURCE:
            raise ValueError(f"source size out of bounds: {name}")
        return subprocess.check_output(["git", "-C", root, "cat-file", "blob", spec])
    return read_bounded(Path(root) / name, MAX_SOURCE)


def read_bounded(path, limit):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= limit:
        raise ValueError(f"expected bounded regular file: {path.name}")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if not 0 < len(data) <= limit:
        raise ValueError(f"unexpected size: {path.name}")
    return data


def positive_number(text):
    if not re.fullmatch(r"[1-9][0-9]{0,9}", text or "") or int(text) > 2147483647:
        raise ValueError("missing or invalid positive versionCode")
    return int(text)


def module_metadata(data, tag):
    props = {}
    for line in data.decode("utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if key in props:
            raise ValueError("duplicate module.prop property")
        props[key] = value
    ver = props.get("version", "")
    if props.get("id") != "magpie" or not TAG.fullmatch(ver) or (tag and ver != tag):
        raise ValueError("module.prop ID/version does not match the expected tag")
    return ver, positive_number(props.get("versionCode"))


def expected_payload(root, ref, tag):
    data = {name: source_bytes(root, ref, name) for name in PAYLOAD}
    version, code = module_metadata(data["module.prop"], tag)
    parser = ET.fromstring(source_bytes(root, ref, "tile-app/AndroidManifest.xml"))
    tile = positive_number(parser.get("{http://schemas.android.com/apk/res/android}versionCode"))
    data["tile-version"] = f"{tile}\n".encode("ascii")
    return version, code, data


def zip_entries(path, limits, outer_limit):
    """No extractall, directories, duplicate names, links, or unbounded inflation."""
    read_bounded(path, outer_limit)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) != len(limits) or {entry.filename for entry in entries} != set(limits):
            raise ValueError("archive entries differ from exact allowlist")
        values = {}
        for entry in entries:
            mode = entry.external_attr >> 16
            if (entry.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG)
                    or entry.flag_bits & 1 or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                    or not 0 < entry.file_size <= limits[entry.filename]):
                raise ValueError(f"unexpected archive entry metadata: {entry.filename!r}")
            with archive.open(entry) as source:
                data = source.read(limits[entry.filename] + 1)
            if len(data) != entry.file_size:
                raise ValueError("archive entry size changed")
            values[entry.filename] = (data, mode)
        return values


def verify_module(file, expected):
    entries = zip_entries(file, dict.fromkeys(expected, MAX_SOURCE) | {APK: MAX_APK}, MAX_MODULE)
    for name, (data, mode) in entries.items():
        if mode & 0o7777 != PAYLOAD.get(name, 0o644):
            raise ValueError(f"unexpected archive mode: {name}")
        if name != APK and data != expected[name]:
            raise ValueError(f"module payload does not match the source: {name}")


def package(args):
    version, _, data = expected_payload(args.source, args.git_ref, args.tag)
    apk = read_bounded(args.apk, MAX_APK)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    final = output / f"magpie-{version}.zip"
    fd, tmp = tempfile.mkstemp(prefix=".magpie-", suffix=".zip", dir=output)
    os.close(fd)
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, body in sorted((data | {APK: apk}).items()):
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | PAYLOAD.get(name, 0o644)) << 16
                archive.writestr(entry, body, zipfile.ZIP_DEFLATED, compresslevel=9)
        verify_module(tmp, data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, final)
    finally:
        Path(tmp).unlink(missing_ok=True)
    print(final)


def unwrap(args):
    if args.kind == "unsigned":
        allowed = {UNSIGNED: MAX_APK}
    else:
        if not args.tag or not TAG.fullmatch(args.tag):
            raise ValueError("signed artifacts require a valid tag")
        allowed = {f"magpie-{args.tag}.zip": MAX_MODULE, "SHA256SUMS": 256}
    entries = zip_entries(args.file, allowed, MAX_MODULE * 2)
    dest = Path(args.output)
    # Require a fresh directory; never overwrite the policy checkout or previous material.
    dest.mkdir(mode=0o700)
    for name, (data, _) in entries.items():
        with (dest / name).open("xb") as output:
            output.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="cmd", required=True)
    for name in ("package", "verify"):
        cmd = subs.add_parser(name)
        cmd.add_argument("--source", required=True)
        cmd.add_argument("--git-ref")
        cmd.add_argument("--tag")
        if name == "package":
            cmd.add_argument("--apk", required=True)
            cmd.add_argument("--output", required=True)
        else:
            cmd.add_argument("--file", required=True)
    cmd = subs.add_parser("unwrap")
    cmd.add_argument("kind", choices=("unsigned", "signed"))
    cmd.add_argument("file")
    cmd.add_argument("output")
    cmd.add_argument("--tag")
    args = parser.parse_args()
    try:
        if args.cmd == "package":
            package(args)
        elif args.cmd == "verify":
            version, code, data = expected_payload(args.source, args.git_ref, args.tag)
            verify_module(args.file, data)
            digest = hashlib.sha256(read_bounded(args.file, MAX_MODULE)).hexdigest()
            print(json.dumps({"version": version, "versionCode": code, "sha256": digest}))
        else:
            unwrap(args)
    except (ValueError, OSError, zipfile.BadZipFile, ET.ParseError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"release artifact rejected: {exc}\n")


if __name__ == "__main__":
    main()
