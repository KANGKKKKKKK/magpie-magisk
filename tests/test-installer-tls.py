#!/usr/bin/env python3
"""Use temporary loopback servers and a disposable CA to check the production TLS policy."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTlsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="magpie-tls-fixture-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.cert = cls.root / "ca.pem"
        key = cls.root / "disposable.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-addext", "subjectAltName=IP:127.0.0.1", "-subj", "/CN=local-fixture",
                        "-keyout", str(key), "-out", str(cls.cert)], check=True, capture_output=True, timeout=12)
        cls.requests = []
        cls.file = b'#!/bin/sh\nprintf "magpie 9.9.9\\n"\n'

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                secure = isinstance(self.connection, ssl.SSLSocket)
                cls.requests.append((secure, self.path))
                if self.path in ("/downgrade", "/redirect"):
                    self.send_response(302)
                    target = cls.plain if self.path == "/downgrade" else cls.secure
                    self.send_header("Location", target + "/manifest.json")
                    self.end_headers()
                    return
                if self.path == "/fake-bin":
                    payload = cls.file
                else:
                    fields = {"url": cls.secure + "/fake-bin", "sha256": hashlib.sha256(cls.file).hexdigest(), "size": len(cls.file)}
                    if self.path == "/insecure-asset.json":
                        fields["url"] = cls.plain + "/fake-bin"
                    if self.path == "/missing-size.json":
                        fields.pop("size")
                    manifest = {"version": "9.9.9", "assets": {"magpie-cli-android-arm64": fields}}
                    payload = json.dumps(manifest).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        secure = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.plain = f"http://127.0.0.1:{plain.server_port}"
        cls.secure = f"https://127.0.0.1:{secure.server_port}"
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cls.cert, key)
        secure.socket = tls.wrap_socket(secure.socket, server_side=True)
        for server in (plain, secure):
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.addClassCleanup(server.server_close)
            cls.addClassCleanup(server.shutdown)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.script = self.dir / "scripts/install.sh"
        self.script.parent.mkdir()
        script = (ROOT / "scripts/install.sh").read_text()
        lines = [f'CONF="{self.dir}/cfg"' if line.startswith("CONF=") else line for line in script.splitlines()]
        self.script.write_text("\n".join(lines) + "\n")  # no protocol changes in this test
        (self.dir / "cfg").write_text(f'magpie_path="{self.dir}"\n')
        lib = self.dir / "scripts/lib.sh"
        shutil.copyfile(ROOT / "scripts/lib.sh", lib)
        with lib.open("a") as out:
            out.write(f'\nmagpie_path_installable() {{ [ "$1" = "{self.dir}" ]; }}\n')
        # Verify that user configuration is ignored, including a permissive curlrc.
        (self.dir / ".curlrc").write_text("insecure\n")
        self.requests.clear()

    def run_installer(self, url, *args, ok=False, trust=True):
        env = dict(PATH=os.environ["PATH"], HOME=str(self.dir), LC_ALL="C.UTF-8", CURL_HOME=str(self.dir),
                   MAGPIE_MANIFEST_URL=url, MAGPIE_ALLOW_ANY_ARCH="1", MAGPIE_DL_STALL="2", MAGPIE_DL_TIMEOUT="5")
        if trust:
            env["MAGPIE_TLS_CA_BUNDLE"] = str(self.cert)
        result = subprocess.run(["sh", str(self.script), *args], env=env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_trusted_https_redirect_installs_exact_bytes(self):
        self.run_installer(self.secure + "/redirect", "install", "--yes", ok=True)
        self.assertEqual((self.dir / "bin/magpie").read_bytes(), self.file)
        self.assertTrue(all(secure for secure, _ in self.requests))

    def test_untrusted_certificate_rejected_even_with_curlrc(self):
        self.run_installer(self.secure + "/manifest.json", "plan", trust=False)
        self.assertFalse(self.requests)

    def test_initial_http_does_not_connect(self):
        self.run_installer(self.plain + "/manifest.json", "plan")
        self.assertFalse(self.requests)

    def test_https_to_http_redirect_is_not_followed(self):
        self.run_installer(self.secure + "/downgrade", "plan")
        self.assertTrue(self.requests)
        self.assertTrue(all(secure and path == "/downgrade" for secure, path in self.requests))

    def test_insecure_asset_is_not_used_even_over_trusted_manifest(self):
        self.run_installer(self.secure + "/insecure-asset.json", "install", "--yes")
        self.assertTrue(all(secure and path == "/insecure-asset.json" for secure, path in self.requests))
        self.assertFalse((self.dir / "bin/magpie").exists())

    def test_missing_size_rejects_manifest_before_download(self):
        out = self.run_installer(self.secure + "/missing-size.json", "install", "--yes")
        self.assertIn("正整数资产大小", out)
        self.assertTrue(all(secure and path == "/missing-size.json" for secure, path in self.requests))
        self.assertFalse((self.dir / "bin/magpie").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
