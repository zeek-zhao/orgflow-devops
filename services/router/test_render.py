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
sys.path.insert(0, str(Path(__file__).resolve().parent))
from render import RouterHandler, parse_routes, apply_env, render, write_if_changed  # noqa: E402
ROUTES = ROOT / "config/routes.yaml"
SCRIPT = ROOT / "services/router/render.py"
RELOAD = ROOT / "services/router/reload.sh"


def declared_sites():
    """站点子域与数量从 config/routes.yaml 现算，不写死。

    原先这个文件里四处硬编码 8。加一条路由就要改四处断言，而改的人多半是把 8 改成 10、
    跑绿了事 —— 不会去想「渲染器到底有没有把这条渲出来」。改成从配置推导之后，断言变成
    「输出里有的 == 配置里声明的」，测的是渲染器本身，而不是一个会随配置漂的常量。
    """
    _, routes = parse_routes(ROUTES)
    return [r["subdomain"] for r in routes]


def declared_names():
    """路由名清单，同样从配置推导 —— 写死一份名字等于给「加路由」设了个改测试的坎。"""
    _, routes = parse_routes(ROUTES)
    return [r.get("name", r["subdomain"]) for r in routes]


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

    def test_domain_sites_match_config_and_output_is_stable(self):
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertIn("\tlocal_certs", content)
        sites = declared_sites()
        self.assertGreaterEqual(len(sites), 8, "路由数突然变少，先确认是不是删错了")
        for sub in sites:
            self.assertIn(f"https://{sub}.org-devops.com {{", content)
        self.assertEqual(content.count("reverse_proxy "), len(sites))
        # #86 后唯一受网关保护的是 docs 站点
        self.assertEqual(content.count("forward_auth "), 1)
        # 域名路由后不应再有路径匹配块(ADR-13);
        # docs 站点内部的 handle /oauth2/* 是站点内路由,不算站点级路径入口
        self.assertNotIn("handle_path", content)
        self.assertNotIn("handle /jenkins", content)
        self.assertNotIn("handle /ldapadmin", content)
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
        self.env = dict(self.env, GATEWAY_DOMAIN="example.internal")
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertIn("https://jenkins.example.internal {", content)
        # 认证域名跟着 name: auth 那条路由走，没有独立的环境变量可覆盖
        self.assertIn("https://docs.example.internal/oauth2/start", content)
        self.assertNotIn("org-devops.com", content)

    def test_auth_route_is_required(self):
        """登录跳转的目标域名只能来自 routes.yaml 里 name: auth 的站点。"""
        self.routes.write_text(
            'routes:\n'
            '  - name: jenkins\n    subdomain: jenkins\n    upstream: jenkins:8080\n'
            '    auth: true\n'
        )
        result = self.run_render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺少 name: auth 的路由", result.stderr)
        self.assertFalse(self.out.exists())

    def test_auth_route_subdomain_drives_the_redirect(self):
        """#86 后受保护站点只有 docs,跳转固定落 docs 域;auth 改名只影响其自身站点块。"""
        self.routes.write_text(
            self.routes.read_text().replace(
                "  - name: auth\n    subdomain: auth\n",
                "  - name: auth\n    subdomain: sso\n",
            )
        )
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertIn("https://sso.org-devops.com {", content)
        self.assertIn(
            "redir * https://docs.org-devops.com/oauth2/start"
            "?rd={scheme}://{host}{uri} 302", content)
        self.assertNotIn("https://auth.org-devops.com/oauth2/start", content)

    def test_docs_is_the_only_forward_auth_site(self):
        """#86:jenkins/ldapadmin 摘网关;docs 特例跳转落 docs 域(单域闭环)。"""
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertEqual(content.count("forward_auth "), 1)
        docs_block = content.split("https://docs.", 1)[1].split("\nhttps://", 1)[0]
        self.assertIn("forward_auth @notoauth2 oauth2-proxy:4180", docs_block)
        self.assertIn("redir * https://docs.org-devops.com/oauth2/start", docs_block)
        self.assertIn("reverse_proxy oauth2-proxy:4180", docs_block)
        self.assertIn("root * /srv/docs", docs_block)
        self.assertIn("file_server", docs_block)

    def test_jenkins_site_is_off_the_gateway(self):
        """#86:jenkins 摘掉网关(直连 LDAP 由 A4/#87 落地),站点块只剩反代。"""
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        jenkins = content.split("https://jenkins.org-devops.com {", 1)[1].split("\nhttps://", 1)[0]
        self.assertNotIn("forward_auth", jenkins)
        self.assertIn("reverse_proxy jenkins:8080", jenkins)

    def test_ldapadmin_site_is_off_the_gateway(self):
        """#86:phpLDAPadmin 自带 LDAP 登录,摘掉网关鉴权(站点块只剩反代)。"""
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        ldapadmin = content.split("https://ldapadmin.org-devops.com {", 1)[1].split("\nhttps://", 1)[0]
        self.assertNotIn("forward_auth", ldapadmin)
        self.assertIn("reverse_proxy ldapadmin:80", ldapadmin)

    def test_auth_defaults_to_false_and_explicit_false_is_unprotected(self):
        self.routes.write_text(
            'routes:\n'
            '  - subdomain: legacy\n    upstream: legacy:80\n'
            '  - subdomain: public\n    upstream: public:80\n    auth: false\n'
            '  - subdomain: private\n    upstream: private:80\n    auth: true\n'
            # 认证站点本身不设 auth:true，但必须存在：跳转目标由它决定
            '  - name: auth\n    subdomain: auth\n    upstream: oauth2-proxy:4180\n'
        )
        self.assertEqual(self.run_render().returncode, 0)
        content = self.out.read_text()
        self.assertEqual(content.count("reverse_proxy "), 4)
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
                self.assertEqual(json.load(response), {"ok": True, "routes": len(declared_sites())})
            # 换成一份只有两个站点的配置：auth 路由必须留着，否则渲染会直接报错
            self.routes.write_text(
                'routes:\n'
                '  - subdomain: one\n    upstream: one:80\n'
                '  - name: auth\n    subdomain: auth\n    upstream: oauth2-proxy:4180\n'
            )
            self.wait_for(lambda: "one:80" in self.out.read_text())
            with urllib.request.urlopen(url, timeout=2) as response:
                self.assertEqual(json.load(response), {"ok": True, "routes": 2})
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
                    self.assertEqual(json.load(response), {"ok": True, "routes": len(declared_sites())})

    def test_healthz_rejects_stale_artifact(self):
        """#117：产物被外部改坏/删掉时 /healthz 必须 503，不能拿缓存状态报绿。

        真机事故：`make clean` 删掉 out/ 再重建，容器内 bind mount 指向被删的旧
        inode，watch 因为 routes.yaml 的 mtime 没变而不重渲染；旧的 healthz 只看
        「读到过几条配置」，于是配置改了、Caddy 没更新，健康检查照样全绿。
        """
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with self.watch("", port):
            self.wait_for(self.out.exists)
            url = f"http://127.0.0.1:{port}/healthz"
            expected_ok = {"ok": True, "routes": len(declared_sites())}
            expected_bad = {"ok": False, "routes": len(declared_sites())}

            with urllib.request.urlopen(url, timeout=2) as response:
                self.assertEqual(json.load(response), expected_ok)

            original = self.out.read_text()

            def expect_503():
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(url, timeout=2)
                self.assertEqual(error.exception.code, 503)
                self.assertEqual(json.load(error.exception), expected_bad)

            self.out.write_text("# 故意改坏：模拟外部覆盖了产物\n")
            expect_503()

            self.out.unlink()  # 模拟 rm -rf out 之后产物不存在
            expect_503()

            self.out.write_text(original)  # 恢复后必须重新变绿
            with urllib.request.urlopen(url, timeout=2) as response:
                self.assertEqual(json.load(response), expected_ok)

    def test_clean_target_never_removes_out_dir(self):
        """Makefile 的命令行（不含注释）不得出现 rm -rf out —— 见 #117。"""
        lines = (ROOT / "Makefile").read_text(encoding="utf-8").splitlines()
        for line in lines:
            if line.startswith("\t"):
                self.assertNotIn("rm -rf out", line)

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
                self.assertEqual(json.load(response), {"ok": True, "routes": len(declared_sites())})


class RouteApiTests(unittest.TestCase):
    """#61 注册 API：校验、写回 routes.yaml、HTTP 全流程。

    routes.yaml 仍是唯一真源：API 只是它的写入口，写前校验、写后渲染。
    """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.routes = Path(self.directory.name) / "routes.yaml"
        self.routes.write_bytes(ROUTES.read_bytes())
        self.out = Path(self.directory.name) / "Caddyfile"

    def sha(self):
        import hashlib
        return hashlib.sha256(self.routes.read_bytes()).hexdigest()

    def test_post_valid_appends_and_returns_entry(self):
        with RouterAPIServer(self.routes, self.out) as api:
            status, body = api.request("POST", "/routes", {
                "name": "demo", "host": f"demo.{GATEWAY_DOMAIN}",
                "upstream": "caddy:80",
            })
            self.assertEqual(status, 201)
            self.assertEqual(body["route"]["subdomain"], "demo")
            # host 是 FQDN 时剥掉网关域名后缀，文件里仍写 subdomain 口径
            self.assertIn("subdomain: demo", self.routes.read_text())

    def test_post_invalid_is_400_and_file_unchanged(self):
        # 反证核心（#61 验收）：非法输入必须在写之前被拒——文件一个字节都不能动。
        bad_payloads = (
            {"name": "demo", "host": "", "upstream": "caddy:80"},        # host 空
            {"name": "demo", "subdomain": "demo"},                        # 缺 upstream
            {"name": "Bad_Name", "subdomain": "x", "upstream": "u"},      # name 非法
            {"name": "demo", "subdomain": "jenkins", "upstream": "u"},    # 重复 subdomain
            {"name": "homepage", "subdomain": "demo2", "upstream": "u"},  # 重复 name
            {"name": "demo", "subdomain": GATEWAY_DOMAIN,
             "upstream": "u"},                                            # subdomain=网关域名
        )
        with RouterAPIServer(self.routes, self.out) as api:
            before = self.sha()
            for payload in bad_payloads:
                status, body = api.request("POST", "/routes", payload)
                self.assertEqual(status, 400, payload)
                self.assertTrue(body.get("error"), payload)
                self.assertEqual(self.sha(), before, f"文件被改动了: {payload}")

    def test_post_json_garbage_is_400(self):
        with RouterAPIServer(self.routes, self.out) as api:
            self.assertEqual(api.request_raw("POST", "/routes", b"{not json")[0], 400)
            self.assertEqual(api.request("POST", "/routes", None)[0], 400)

    def test_get_routes_returns_valid_json(self):
        with RouterAPIServer(self.routes, self.out) as api:
            status, body = api.request("GET", "/routes")
            self.assertEqual(status, 200)
            self.assertEqual(body["gateway_domain"], GATEWAY_DOMAIN)
            self.assertEqual([r["name"] for r in body["routes"]], declared_names())

    def test_delete_removes_entry_and_keeps_rest(self):
        with RouterAPIServer(self.routes, self.out) as api:
            api.request("POST", "/routes", {"name": "demo", "subdomain": "demo",
                                            "upstream": "caddy:80"})
            text = self.routes.read_text()
            status, body = api.request("DELETE", "/routes/demo")
            self.assertEqual(status, 200)
            self.assertNotIn("subdomain: demo", self.routes.read_text())
            # 其余条目与注释原样保留
            for keep in ("name: jenkins", "name: homepage", "# 统一入口"):
                self.assertIn(keep, self.routes.read_text())
            status, _ = api.request("DELETE", "/routes/demo")
            self.assertEqual(status, 404)

    def test_delete_protects_auth_route(self):
        with RouterAPIServer(self.routes, self.out) as api:
            status, body = api.request("DELETE", "/routes/auth")
            self.assertEqual(status, 400)
            self.assertIn("不能删除", body["error"])

    def test_api_write_feeds_the_renderer(self):
        settings, routes = parse_routes(str(self.routes))
        write_if_changed(str(self.out), render(apply_env(settings), routes))
        with RouterAPIServer(self.routes, self.out) as api:
            before = self.out.read_text()
            api.request("POST", "/routes", {"name": "demo", "subdomain": "demo",
                                            "upstream": "caddy:80"})
            self.assertIn(f"https://demo.{GATEWAY_DOMAIN} {{", self.out.read_text())
            api.request("DELETE", "/routes/demo")
            self.assertEqual(self.out.read_text(), before)


GATEWAY_DOMAIN = "org-devops.com"


class RouterAPIServer:
    """起一个真实 RouterHandler（临时端口），单元测试直接发 HTTP。"""

    def __init__(self, routes_path, out_path):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), RouterHandler)
        self.server.routes_path = str(routes_path)
        self.server.out_path = str(out_path)
        self.server.admin_url = ""
        self.server.ca_dir = ""
        self.server.route_lock = threading.Lock()
        self.server.health_state = {"routes_count": None}
        # 单测不连 Caddy，但渲染和落盘要走真实逻辑
        def _once(force_reload=False):
            settings, routes = parse_routes(str(routes_path))
            write_if_changed(str(out_path), render(apply_env(settings), routes))
        self.server.once = _once
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.02})
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def request_raw(self, method, path, body=None, headers=None):
        req = urllib.request.Request(self.base + path, data=body, method=method,
                                     headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode() or "{}")

    def request(self, method, path, payload=None):
        body = json.dumps(payload).encode() if payload is not None else None
        headers = {"Content-Type": "application/json"} if payload is not None else {}
        return self.request_raw(method, path, body, headers)


if __name__ == "__main__":
    unittest.main()

