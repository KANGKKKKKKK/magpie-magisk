#!/usr/bin/env python3
"""生成 install.sh 测试用的夹具：一个假本体 + 四个清单变体。

用法:
    python3 tests/make-fixtures.py /tmp/fx
    (cd /tmp/fx && python3 -m http.server 8899) &
    TEST_SRV=http://127.0.0.1:8899 sh tests/test-install.sh

假本体是一个能应答 --version 的脚本，够 install.sh 的自检通过；
另外造一个「能下载但跑不起来」的变体（用当前平台的原生 /bin/true，
在 Android 上它因为缺 glibc 装载器而无法执行）。
"""
import hashlib, json, os, shutil, sys

out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fx"
os.makedirs(out, exist_ok=True)
base = "http://127.0.0.1:8899"

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
