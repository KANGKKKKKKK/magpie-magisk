#!/usr/bin/env python3
"""生成 install.sh 测试用的夹具：一个假本体 + 四个清单变体。

用法:
    python3 tests/make-fixtures.py /tmp/fx
    (cd /tmp/fx && python3 -m http.server 8899) &
    TEST_SRV=http://127.0.0.1:8899 sh tests/test-install.sh

换端口时两处必须是同一个值，否则清单里的下载地址会指向别的端口，
测试会出现一堆看着像 bug 的假失败:

    TEST_SRV=http://127.0.0.1:18999
    python3 tests/make-fixtures.py /tmp/fx --base "$TEST_SRV"
    (cd /tmp/fx && python3 -m http.server 18999) &
    TEST_SRV="$TEST_SRV" sh tests/test-install.sh

假本体是一个能应答 --version 的脚本，够 install.sh 的自检通过；
另外造一个「能下载但跑不起来」的变体（用当前平台的原生 /bin/true，
在 Android 上它因为缺 glibc 装载器而无法执行）。
"""
import argparse
import hashlib
import json
import os
import shutil
import sys

argp = argparse.ArgumentParser(description="生成 magpie 安装器的测试夹具")
argp.add_argument("out", nargs="?", default="/tmp/fx", help="输出目录（默认 /tmp/fx）")
argp.add_argument(
    "--base",
    default="http://127.0.0.1:8899",
    help="清单里写死的服务根地址（默认 http://127.0.0.1:8899）",
)
args = argp.parse_args()

out = args.out
base = args.base.rstrip("/")
if not base.startswith(("http://", "https://")):
    sys.exit("--base 必须以 http:// 或 https:// 开头：%s" % base)
os.makedirs(out, exist_ok=True)

# 假本体：应答 --version
# shebang 按运行平台选：Android 上没有 /bin/sh，桌面 Linux 上没有 /system/bin/sh
SHEBANG = "/system/bin/sh" if os.path.exists("/system/bin/sh") else "/bin/sh"
fake = os.path.join(out, "fake-bin")
with open(fake, "w") as f:
    f.write("#!%s\ncase \"$1\" in\n  --version) echo \"magpie 9.9.9\" ;;\n  *) exit 0 ;;\nesac\n" % SHEBANG)
os.chmod(fake, 0o755)
fdata = open(fake, "rb").read()
fsum = hashlib.sha256(fdata).hexdigest()


def manifest(asset_url, size, sha, with_github=True):
    a = {"url": asset_url, "api": base + "/asset/1", "size": size, "sha256": sha}
    if with_github:
        a["github"] = asset_url
    return {
        "version": "9.9.9",
        "notes": "夹具",
        "url": base + "/tag/v9.9.9",
        "published": "2026-01-01T00:00:00Z",
        "assets": {"magpie-cli-android-arm64": a},
    }


def dump(name, obj):
    with open(os.path.join(out, name), "w") as f:
        json.dump(obj, f, ensure_ascii=False)
    print("  " + name)


print("夹具写入 " + out)
dump("manifest.json", manifest(base + "/fake-bin", len(fdata), fsum))
dump("manifest-bad.json", manifest(base + "/fake-bin", len(fdata), "0" * 64))
dump("manifest-badsize.json", manifest(base + "/fake-bin", len(fdata) + 12345, fsum))

# 跑不起来的变体：拿本机一个原生二进制冒充
cand = None
for c in ("/bin/true", "/usr/bin/true"):
    if os.path.exists(c):
        cand = c
        break
if cand:
    wrong = os.path.join(out, "wrong-arch")
    shutil.copy(cand, wrong)
    os.chmod(wrong, 0o755)
    wdata = open(wrong, "rb").read()
    dump("manifest-wrongarch.json",
         manifest(base + "/wrong-arch", len(wdata), hashlib.sha256(wdata).hexdigest()))
else:
    print("  跳过 wrongarch（找不到可冒充的原生二进制）")
print("完成")
