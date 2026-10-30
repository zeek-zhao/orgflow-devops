import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ROUTES = ROOT / "config/routes.yaml"
SCRIPT = ROOT / "services/router/render.py"
RELOAD = ROOT / "services/router/reload.sh"


@contextlib.contextmanager
def admin_server():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            self.server.requests.append((self.path, self.headers["Content-Type"], body))
            self.send_response(self.server.status)
            self.end_headers()
            self.wfile.write(b"invalid test configuration" if self.server.status == 400 else b"")

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.status = 200
    server.requests = []
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02})
    thread.start()
    try:
        yield server, f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class RouterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.out = Path(self.directory.name) / "Caddyfile"
        self.routes = Path(self.directory.name) / "routes.yaml"
        self.routes.write_bytes(ROUTES.read_bytes())
        self.env = dict(os.environ, CADDY_ADMIN_URL="")

    def run_render(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--routes", str(self.routes),
             "--out", str(self.out), *args],
            env=self.env, capture_output=True, text=True, timeout=15,
        )

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("watch did not reach expected state within 5 seconds")

    @contextlib.contextmanager
    def watch(self, url):
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--routes", str(self.routes),
             "--out", str(self.out), "--watch", "--interval", "0.05", "--admin", url],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            yield process
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.communicate(timeout=5)

    def test_four_routes_and_unchanged_output(self):
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertIn("\thandle /jenkins* {", content)
        for path in ("nexus", "ldapadmin", "auth"):
            self.assertIn(f"\thandle_path /{path}* {{", content)
        self.assertEqual(content.count("reverse_proxy "), 4)
        before = self.out.stat()
        self.assertEqual(self.run_render().returncode, 0)
        self.assertEqual(self.out.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.out.stat().st_ino, before.st_ino)

    def test_reload_success_and_rejection_preserve_last_good_file(self):
        self.out.write_text("old file\n")
        with admin_server() as (server, url):
            server.status = 400
            rejected = self.run_render("--admin", url)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("HTTP 400", rejected.stderr)
            self.assertIn("invalid test configuration", rejected.stderr)
            self.assertEqual(self.out.read_text(), "old file\n")
            server.status = 200
            self.assertEqual(self.run_render("--admin", url).returncode, 0)
            self.assertEqual(server.requests[-1][0:2], ("/load", "text/caddyfile"))
            self.assertEqual(server.requests[-1][2], self.out.read_bytes())
            good = self.out.read_bytes()
            self.routes.write_text(self.routes.read_text().replace("jenkins:8080", "new:8080"))
            server.status = 400
            self.assertNotEqual(self.run_render("--admin", url).returncode, 0)
            self.assertEqual(self.out.read_bytes(), good)
        self.assertEqual(sorted(p.name for p in self.out.parent.iterdir()),
                         ["Caddyfile", "routes.yaml"])

    def test_rejected_first_load_does_not_create_output(self):
        with admin_server() as (server, url):
            server.status = 400
            self.assertNotEqual(self.run_render("--admin", url).returncode, 0)
            self.assertFalse(self.out.exists())

    def test_shell_unreachable_even_when_output_is_unchanged(self):
        self.assertEqual(self.run_render().returncode, 0)
        before = self.out.stat()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            env = dict(self.env, CADDY_ADMIN_URL=f"http://127.0.0.1:{sock.getsockname()[1]}",
                       ROUTES_FILE=str(self.routes))
            result = subprocess.run(
                ["bash", str(RELOAD), str(self.out)], cwd=ROOT, env=env,
                capture_output=True, text=True, timeout=15,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot reach Caddy admin", result.stderr)
        self.assertIn("check that Caddy is running", result.stderr)
        self.assertEqual(self.out.stat().st_mtime_ns, before.st_mtime_ns)

    def test_shell_propagates_http_failure_and_success(self):
        self.out.write_text("old file\n")
        with admin_server() as (server, url):
            env = dict(self.env, CADDY_ADMIN_URL=url, ROUTES_FILE=str(self.routes))
            for status in (400, 200):
                server.status = status
                result = subprocess.run(
                    ["bash", str(RELOAD), str(self.out)], cwd=ROOT, env=env,
                    capture_output=True, text=True, timeout=15,
                )
                if status == 400:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("invalid test configuration", result.stderr)
                    self.assertEqual(self.out.read_text(), "old file\n")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(server.requests[-1][2], self.out.read_bytes())

    def test_watch_retries_and_handles_later_changes(self):
        self.out.write_text("old file\n")
        with admin_server() as (server, url):
            server.status = 400
            with self.watch(url):
                self.wait_for(lambda: len(server.requests) >= 2)
                self.assertEqual(self.out.read_text(), "old file\n")
                server.status = 200
                self.wait_for(lambda: "jenkins:8080" in self.out.read_text())
                count = len(server.requests)
                before = self.out.stat().st_mtime_ns
                time.sleep(0.15)
                self.assertEqual(len(server.requests), count)
                self.assertEqual(self.out.stat().st_mtime_ns, before)
                self.routes.unlink()
                time.sleep(0.1)
                self.routes.write_text(ROUTES.read_text().replace("jenkins:8080", "new:8080"))
                self.wait_for(lambda: "new:8080" in self.out.read_text())

    def test_watch_bootstrap_retries_even_with_matching_output(self):
        with admin_server() as (server, url):
            server.status = 400
            with self.watch(url):
                self.wait_for(lambda: self.out.exists() and len(server.requests) >= 2)
                before = self.out.stat().st_mtime_ns
                server.status = 200
                self.wait_for(lambda: len(server.requests) >= 3)
                time.sleep(0.15)
                count = len(server.requests)
                time.sleep(0.15)
                self.assertEqual(len(server.requests), count)
                self.assertEqual(self.out.stat().st_mtime_ns, before)

    def test_interval_must_be_finite_and_positive(self):
        for value in ("0", "-1", "nan", "inf"):
            with self.subTest(value=value):
                result = self.run_render("--watch", "--interval", value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--interval must be", result.stderr)


if __name__ == "__main__":
    unittest.main()
