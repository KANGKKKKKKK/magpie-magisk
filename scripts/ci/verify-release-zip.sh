#!/bin/sh
# 正式 Release ZIP 的离线硬门槛；不允许缺少磁贴的历史版本降级通过。
#   SOURCE_ROOT=/path/to/tag-source EXPECTED_CERT_FILE=/trusted/tile-cert-sha256.txt \
#     sh /path/to/verify-release-zip.sh <zip> <tag>
# SOURCE_ROOT 默认用当前源码目录，或脚本所在仓库；复制脚本到临时目录时应显式传入。
# EXPECTED_CERT_FILE 必须是可信的绝对路径，默认读校验工具旁的公开指纹文件，
# 不从待校验的 ZIP / 历史源码里寻找或推导信任值。
set -eu

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

[ "$#" -eq 2 ] || fail "用法: $0 <zip> <tag>"
[ -n "$2" ] || fail "tag 不能为空"
command -v python3 >/dev/null 2>&1 || fail "需要 python3 校验 ZIP 与元数据"
# 必须在任何 cd 之前解析调用者提供的相对 ZIP 路径。
ZIP=$(python3 -I - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve(strict=True)
if not p.is_file():
    sys.exit("ZIP 不是普通文件")
print(p)
PY
) || fail "zip 不存在或路径无效：$1"
TAG=$2
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "${SOURCE_ROOT+x}" = x ]; then
  [ -n "$SOURCE_ROOT" ] || fail "SOURCE_ROOT 不能为空"
  ROOT=$SOURCE_ROOT
elif [ -f "$PWD/tile-app/AndroidManifest.xml" ]; then
  ROOT=$PWD
else
  ROOT=$HERE/../..
fi
ROOT=$(cd "$ROOT" && pwd) || fail "SOURCE_ROOT 不是有效源码目录"
CERT_FILE=${EXPECTED_CERT_FILE-"$HERE/tile-cert-sha256.txt"}
case "$CERT_FILE" in /*) ;; *) fail "EXPECTED_CERT_FILE 必须是可信指纹文件的绝对路径" ;; esac
[ -f "$CERT_FILE" ] || fail "找不到可信指纹文件：$CERT_FILE（复制工具时需传 EXPECTED_CERT_FILE）"
cd "$ROOT"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== ZIP 安全、完整性与源码元数据"
# 不使用按行解析 unzip -Z1：换行、NUL、重复目录、Unix symlink 等必须按 ZIP 条目检查。
python3 -I - "$ZIP" "$TAG" "$ROOT" "$CERT_FILE" "$W" <<'PY'
import json
from pathlib import Path
import re
import stat
import sys
import unicodedata
import xml.etree.ElementTree as ET
import zipfile

archive, tag, source, cert_file, work = sys.argv[1:]
work = Path(work)

def fail(message):
    sys.exit("::error::" + message)

def number(value, label):
    if not re.fullmatch(r"[0-9]+", value):
        fail(f"{label} 不是纯数字：{value!r}")
    return value

try:
    certs = [line.strip() for line in Path(cert_file).read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    if len(certs) != 1 or not re.fullmatch(r"[0-9a-fA-F]{64}", certs[0]):
        fail("可信证书指纹必须恰好一行、64 个十六进制字符（不带分隔符）")

    with zipfile.ZipFile(archive) as z:
        entries = {}
        for info in z.infolist():
            name = info.orig_filename  # filename 会被 zipfile 在 NUL 处截断。
            if (not name or name.startswith("/") or "\\" in name
                    or any(unicodedata.category(c).startswith("C") for c in name)
                    or not re.fullmatch(r"[A-Za-z0-9._+/@=\-]+", name)):
                fail(f"ZIP 含绝对路径、反斜杠或危险字符：{name!r}")
            parts = name.rstrip("/").split("/")
            if any(p in ("", ".", "..") for p in parts):
                fail(f"ZIP 含非规范路径或 .. 路径：{name!r}")
            key = "/".join(parts)
            if key in entries:
                fail(f"ZIP 含重复条目或文件/目录冲突：{name!r}")
            mode = stat.S_IFMT(info.external_attr >> 16)
            if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                fail(f"ZIP 含 symlink 或特殊文件：{name!r}")
            if mode == stat.S_IFDIR and not info.is_dir():
                fail(f"ZIP 目录类型与名称不一致：{name!r}")
            if info.flag_bits & 1:
                fail(f"ZIP 不允许加密条目：{name!r}")
            entries[key] = info
        for key in entries:
            parts = key.split("/")
            for i in range(1, len(parts)):
                parent = entries.get("/".join(parts[:i]))
                if parent is not None and not parent.is_dir():
                    fail(f"ZIP 文件被用作父目录：{key!r}")
        bad = z.testzip()
        if bad is not None:
            fail(f"ZIP CRC 校验失败：{bad!r}")
        required = ("module.prop", "service.sh", "action.sh", "uninstall.sh", "customize.sh",
                    "scripts/magpie.service", "META-INF/com/google/android/update-binary",
                    "META-INF/com/google/android/updater-script")
        for name in required:
            if name not in entries or entries[name].is_dir():
                fail(f"ZIP 缺少根目录必需文件：{name}")
        if any(name in entries for name in ("README.md", "CHANGELOG.md", "update.json", "build.sh")):
            fail("ZIP 里混进了仓库文件")
        for name in ("magpie-tile.apk", "tile-version"):
            if name not in entries or entries[name].is_dir():
                fail("正式 Release 必须同时包含 magpie-tile.apk 与 tile-version；"
                     "历史无 APK 的版本不支持正式 Release 恢复，不能绕过磁贴硬门槛")
        props = {}
        for line in z.read("module.prop").decode("utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                fail("module.prop 含无效元数据行")
            key, value = line.split("=", 1)
            if not key or key.strip() != key or key in props:
                fail(f"module.prop 含重复或无效元数据键：{key!r}")
            props[key] = value
        if props.get("version") != tag:
            fail(f"module.prop version {props.get('version')!r} != tag {tag!r}")
        module_code = number(props.get("versionCode", ""), "module.prop versionCode")
        tile_lines = z.read("tile-version").decode("utf-8").splitlines()
        if len(tile_lines) != 1:
            fail("tile-version 必须恰好一行")
        tile_code = number(tile_lines[0], "tile-version")
        (work / "magpie-tile.apk").write_bytes(z.read("magpie-tile.apk"))

    manifest = ET.parse(Path(source) / "tile-app/AndroidManifest.xml").getroot()
    sdk = manifest.findall("uses-sdk")
    if manifest.tag != "manifest" or len(sdk) != 1:
        fail("源码 manifest 必须包含唯一 uses-sdk")
    android = "{http://schemas.android.com/apk/res/android}"
    package = manifest.get("package", "")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+", package):
        fail("源码 manifest 包名无效")
    expected = {
        "package": package,
        "versionCode": number(manifest.get(android + "versionCode", ""), "源码 versionCode"),
        "minSdk": number(sdk[0].get(android + "minSdkVersion", ""), "源码 minSdk"),
        "targetSdk": number(sdk[0].get(android + "targetSdkVersion", ""), "源码 targetSdk"),
        "certificate": certs[0].upper(),
        "tileVersion": tile_code,
    }
    (work / "expected.json").write_text(json.dumps(expected), encoding="utf-8")
    print(f"  ZIP version={tag} versionCode={module_code}；安全与完整性检查通过")
except (OSError, ValueError, RuntimeError, NotImplementedError, ET.ParseError,
        zipfile.BadZipFile, EOFError) as e:
    fail(f"ZIP / 源码元数据校验失败：{e}")
PY

echo "== apksigner 签名校验"
APKSIGNER=$(command -v apksigner || true)
if [ -z "$APKSIGNER" ]; then
  for _cand in "${ANDROID_HOME:-/nonexistent}"/build-tools/*/apksigner; do
    [ -x "$_cand" ] && APKSIGNER=$_cand && break
  done
fi
[ -n "$APKSIGNER" ] || fail "找不到 apksigner，无法校验磁贴签名"
# 独立检查退出码，绝不把 verify 放进 sed / tr / head 管道。
if ! "$APKSIGNER" verify --print-certs "$W/magpie-tile.apk" >"$W/certs.log" 2>"$W/verify.err"; then
  fail "apksigner verify 失败（即使输出了预期指纹也不能通过）"
fi
python3 -I - "$W" <<'PY'
import json
from pathlib import Path
import re
import sys
w = Path(sys.argv[1])
expected = json.loads((w / "expected.json").read_text())["certificate"]
certs = []
for line in (w / "certs.log").read_text(encoding="utf-8").splitlines():
    if "certificate SHA-256 digest:" not in line:
        continue
    digest = line.split("certificate SHA-256 digest:", 1)[1].strip()
    if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        sys.exit("::error::apksigner 输出了无效 SHA-256 证书指纹")
    certs.append(digest.upper())
if not certs:
    sys.exit("::error::apksigner 没有输出证书指纹")
# 同一证书可能在不同签名方案中重复打印；任何额外的非预期证书都拒绝。
if any(cert != expected for cert in certs):
    sys.exit("::error::磁贴证书指纹不匹配（包含非预期签名证书）")
print("  所有签名证书均匹配可信指纹：" + expected)
PY

echo "== APK 包名 / versionCode / min / target"
if ! aapt dump badging "$W/magpie-tile.apk" >"$W/badging.log" 2>"$W/aapt.err"; then
  fail "aapt dump badging 失败"
fi
python3 -I - "$W" <<'PY'
import json
from pathlib import Path
import re
import sys
w = Path(sys.argv[1])
expected = json.loads((w / "expected.json").read_text())
lines = (w / "badging.log").read_text(encoding="utf-8").splitlines()

def fail(message):
    sys.exit("::error::" + message)

def unique_line(prefix):
    matches = [line for line in lines if line.startswith(prefix)]
    if len(matches) != 1:
        fail(f"APK 元数据 {prefix} 必须恰好一行")
    return matches[0]

package = unique_line("package:")
actual = {}
for field, key in (("name", "package"), ("versionCode", "versionCode")):
    values = re.findall(r"(?:^|\s)" + field + r"='([^']*)'", package)
    if len(values) != 1:
        fail(f"APK package 元数据 {field} 缺失或重复")
    actual[key] = values[0]
for field, key in (("sdkVersion", "minSdk"), ("targetSdkVersion", "targetSdk")):
    line = unique_line(field + ":")
    match = re.fullmatch(field + r":'([0-9]+)'", line)
    if not match:
        fail(f"APK 元数据 {field} 格式无效")
    actual[key] = match[1]
for key, value in actual.items():
    if value != expected[key]:
        fail(f"APK {key} {value!r} != 源码 {expected[key]!r}")
if expected["tileVersion"] != actual["versionCode"]:
    fail("tile-version != APK versionCode")
print("  APK 包名、versionCode、minSdk、targetSdk 与源码一致；tile-version 一致")
PY
printf '\nzip 硬门槛校验全部通过: %s (tag %s)\n' "$ZIP" "$TAG"
