import contextlib
import json
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
import urllib.error
import urllib.request

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
    def watch(self, url, health_port=0):
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--routes", str(self.routes),
             "--out", str(self.out), "--watch", "--interval", "0.05", "--admin", url,
             "--health-port", str(health_port)],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            yield process
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.communicate(timeout=5)

    def test_five_domain_sites_and_unchanged_output(self):
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertIn("\tlocal_certs", content)
        for sub in ("jenkins", "nexus", "ldapadmin", "dex", "auth"):
            self.assertIn(f"https://{sub}.org-devops.com {{", content)
        self.assertEqual(content.count("reverse_proxy "), 5)
        self.assertEqual(content.count("forward_auth "), 1)
        # 域名路由后不应再有路径匹配块
        self.assertNotIn("handle_path", content)
        self.assertNotIn("handle /", content)
        before = self.out.stat()
        self.assertEqual(self.run_render().returncode, 0)
        self.assertEqual(self.out.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.out.stat().st_ino, before.st_ino)

    def test_missing_upstream_preserves_previous_output(self):
        self.assertEqual(self.run_render().returncode, 0)
        before = self.out.read_bytes()
        self.routes.write_text('routes:\n  - subdomain: broken\n')
        result = self.run_render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("upstream is required", result.stderr)
        self.assertEqual(self.out.read_bytes(), before)

    def test_duplicate_and_invalid_subdomain_are_rejected(self):
        for text, message in (
            ('routes:\n  - subdomain: dup\n    upstream: a:80\n'
             '  - subdomain: dup\n    upstream: b:80\n', "duplicate subdomain"),
            ('routes:\n  - subdomain: Bad_Case\n    upstream: a:80\n', "invalid subdomain"),
            ('routes:\n  - upstream: a:80\n', "missing subdomain"),
        ):
            with self.subTest(message=message):
                self.routes.write_text(text)
                result = self.run_render()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.out.exists())

    def test_gateway_domain_env_override(self):
        self.env = dict(self.env, GATEWAY_DOMAIN="example.internal", AUTH_SUBDOMAIN="sso")
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertIn("https://jenkins.example.internal {", content)
        self.assertIn("https://sso.example.internal/oauth2/start", content)

    def test_auth_forward_auth_precedes_jenkins_proxy(self):
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        jenkins = content.split("https://jenkins.org-devops.com {", 1)[1]
        self.assertIn("forward_auth oauth2-proxy:4180 {", jenkins)
        self.assertIn("uri /oauth2/auth", jenkins)
        self.assertIn("copy_headers X-Auth-Request-User X-Auth-Request-Email", jenkins)
        self.assertIn("@unauth status 401", jenkins)
        self.assertIn("handle_response @unauth {", jenkins)
        # 认证域名与业务域名分离：跳转必须是绝对地址，rd 带完整原始 URL
        self.assertIn(
            "redir * https://auth.org-devops.com/oauth2/start"
            "?rd={scheme}://{host}{uri} 302", jenkins)
        self.assertLess(jenkins.index("forward_auth"), jenkins.index("reverse_proxy"))
        self.assertEqual(content.count("forward_auth "), 1)

    def test_auth_defaults_to_false_and_explicit_false_is_unprotected(self):
        self.routes.write_text(
            'routes:\n'
            '  - subdomain: legacy\n    upstream: legacy:80\n'
            '  - subdomain: public\n    upstream: public:80\n    auth: false\n'
            '  - subdomain: private\n    upstream: private:80\n    auth: true\n'
        )
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertEqual(content.count("reverse_proxy "), 3)
        self.assertEqual(content.count("forward_auth "), 1)
        self.assertIn("https://public.org-devops.com {", content)
        self.assertNotIn("forward_auth",
                         content.split("https://private.org-devops.com {", 1)[0])

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

    def test_healthz_json_and_updated_route_count(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with self.watch("", port):
            self.wait_for(self.out.exists)
            url = f"http://127.0.0.1:{port}/healthz"
            with urllib.request.urlopen(url, timeout=2) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(response.headers.get_content_type(), "application/json")
                self.assertEqual(json.load(response), {"ok": True, "routes": 5})
            self.routes.write_text('routes:\n  - subdomain: one\n    upstream: one:80\n')
            self.wait_for(lambda: "one:80" in self.out.read_text())
            with urllib.request.urlopen(url, timeout=2) as response:
                self.assertEqual(json.load(response), {"ok": True, "routes": 1})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/other", timeout=2)
            self.assertEqual(error.exception.code, 404)

    def test_invalid_health_port(self):
        for port in ("-1", "65536"):
            result = self.run_render("--watch", "--health-port", port)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--health-port must be", result.stderr)

    def test_healthz_does_not_wait_for_caddy_reload(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with admin_server() as (server, admin):
            server.status = 400
            with self.watch(admin, port):
                self.wait_for(lambda: len(server.requests) >= 2)
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz",
                                            timeout=2) as response:
                    self.assertEqual(json.load(response), {"ok": True, "routes": 5})

    def test_healthz_missing_routes_recovers_in_watch_mode(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.routes.unlink()
        with self.watch("", port):
            url = f"http://127.0.0.1:{port}/healthz"

            def not_ready():
                try:
                    urllib.request.urlopen(url, timeout=1).close()
                except urllib.error.HTTPError as error:
                    self.assertEqual(error.code, 503)
                    self.assertEqual(json.load(error), {"ok": False, "routes": 0})
                    return True
                except urllib.error.URLError:
                    return False
                return False

            self.wait_for(not_ready)
            self.routes.write_bytes(ROUTES.read_bytes())
            self.wait_for(self.out.exists)
            with urllib.request.urlopen(url, timeout=2) as response:
                self.assertEqual(json.load(response), {"ok": True, "routes": 5})


if __name__ == "__main__":
    unittest.main()
