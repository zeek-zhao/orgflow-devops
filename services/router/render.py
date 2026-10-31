#!/usr/bin/env python3
"""路由注册服务：把 routes.yaml 渲染成 Caddyfile，并可热加载到 Caddy。

用法:
  render.py --routes config/routes.yaml --out out/Caddyfile
  render.py --routes config/routes.yaml --out out/Caddyfile --watch

设计：只支持本项目约定的极简 schema，不依赖 PyYAML，保证零第三方依赖。

域名路由模型（M0 ADR-13）：
  每个 route 是一个独立站点 https://<subdomain>.<gateway_domain>
  - gateway_domain 默认取 routes.yaml，可被环境变量 GATEWAY_DOMAIN 覆盖
  - 认证网关域名由 name: auth 那条路由的 subdomain 决定（单一真源，无独立变量）
  - 全部站点用 Caddy 内部 CA（local_certs），不向公网申请证书
  - 未登录访问受保护站点时，跳转到认证域名登录，登录后回到原 URL
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
import re
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

DEFAULT_DOMAIN = "org-devops.com"
# 认证网关站点的路由名。它的 subdomain 就是登录跳转的目标域名。
# 刻意不做成独立环境变量：AUTH_SUBDOMAIN 会与 Caddyfile 站点、dex 的 issuer、
# oauth2-proxy 的 redirect_url 形成四处独立声明，改一处不改另一处就静默错位。
AUTH_ROUTE_NAME = "auth"
SUBDOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")


def _value(s, key):
    return s.split(":", 1)[1].strip().strip('"').strip("'")


def parse_routes(path):
    """解析极简 YAML：顶层键 + routes 列表。返回 (settings, routes)。"""
    settings = {"gateway_domain": DEFAULT_DOMAIN}
    routes = []
    cur = None
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            if s.startswith("- "):
                cur = {}
                routes.append(cur)
                s = s[2:].strip()
            if cur is None:
                if s.startswith("gateway_domain:"):
                    settings["gateway_domain"] = _value(s, "gateway_domain")
                continue
            if s.startswith("name:"):
                cur["name"] = _value(s, "name")
            elif s.startswith("subdomain:"):
                cur["subdomain"] = _value(s, "subdomain")
            elif s.startswith("upstream:"):
                cur["upstream"] = _value(s, "upstream")
            elif s.startswith("auth:"):
                cur["auth"] = _value(s, "auth").lower() in ("true", "1", "yes")
    return settings, routes


def apply_env(settings):
    """环境变量覆盖（部署时由 .env 注入，便于一套配置多环境复用）。"""
    value = os.environ.get("GATEWAY_DOMAIN", "").strip()
    if value:
        settings["gateway_domain"] = value
    return settings


def render(settings, routes):
    domain = settings["gateway_domain"].strip().strip(".")
    if not domain:
        raise ValueError("gateway_domain is required")

    # 顺序很重要：先逐条校验路由，再去解析认证站点。
    # 反过来的话，一份连 subdomain 都没写的配置会先报「缺 auth 路由」，
    # 把真正的输入错误盖住，排查时会被带偏。
    seen = set()
    for r in routes:
        sub = (r.get("subdomain") or "").strip().strip(".")
        if not sub:
            raise ValueError("route missing subdomain (域名路由必须声明 subdomain)")
        if not SUBDOMAIN_RE.match(sub):
            raise ValueError(f"route {sub}: invalid subdomain (只允许小写字母/数字/连字符)")
        if sub in seen:
            raise ValueError(f"route {sub}: duplicate subdomain")
        seen.add(sub)
        if not r.get("upstream", ""):
            raise ValueError(f"route {sub}: upstream is required")

    auth = ""
    for r in routes:
        if (r.get("name") or "").strip() == AUTH_ROUTE_NAME:
            auth = r["subdomain"].strip().strip(".")
            break
    if not auth:
        raise ValueError(
            f"缺少 name: {AUTH_ROUTE_NAME} 的路由；认证网关站点必须自己声明，"
            "否则登录跳转无处可去"
        )

    out = [
        "{",
        "\tadmin 0.0.0.0:2019",
        # 内部 CA：不向公网申请证书，根证书由 scripts/ca-install.sh 分发
        "\tlocal_certs",
        "}",
        "",
    ]

    for r in routes:
        sub = (r.get("subdomain") or "").strip().strip(".")
        up = r["upstream"]

        out.append(f"https://{sub}.{domain} {{")
        if r.get("auth", False):
            out.extend([
                "\tforward_auth oauth2-proxy:4180 {",
                "\t\turi /oauth2/auth",
                "\t\tcopy_headers X-Auth-Request-User X-Auth-Request-Email",
                "\t\t@unauth status 401",
                "\t\thandle_response @unauth {",
                # 认证域名与业务域名分离后，登录跳转必须是绝对地址；
                # rd 带完整原始 URL，登录后回到用户本来要去的页面。
                f"\t\t\tredir * https://{auth}.{domain}/oauth2/start"
                "?rd={scheme}://{host}{uri} 302",
                "\t\t}",
                "\t}",
            ])
        out.append(f"\treverse_proxy {up}")
        out.append("}")
        out.append("")

    return "\n".join(out).rstrip("\n") + "\n"


def content_matches(path, content):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read() == content
    except FileNotFoundError:
        return False


def write_if_changed(path, content):
    if content_matches(path, content):
        return False
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=directory, delete=False
        ) as f:
            temporary = f.name
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)
    return True


def reload_caddy(content, admin_url):
    url = admin_url.rstrip("/") + "/load"
    req = urllib.request.Request(
        url,
        data=content.encode("utf-8"),
        method="POST",
        headers={"Content-Type": "text/caddyfile"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if not 200 <= resp.status < 300:
                raise RuntimeError(f"reload {url}: HTTP {resp.status}")
            return resp.status
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"reload {url}: HTTP {e.code} {e.reason}: {detail}"
        ) from e
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError(
            f"cannot reach Caddy admin at {url}: {e}; "
            "check that Caddy is running and CADDY_ADMIN_URL is correct"
        ) from e


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/healthz":
            self.send_error(404)
            return
        ready = self.server.routes_count is not None
        body = json.dumps({"ok": ready, "routes": self.server.routes_count or 0}).encode("utf-8")
        self.send_response(200 if ready else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--routes", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--admin", default=os.environ.get("CADDY_ADMIN_URL", ""))
    ap.add_argument("--health-port", type=int, default=8090,
                    help="watch-mode health HTTP port (default: 8090)")
    args = ap.parse_args()
    if not math.isfinite(args.interval) or args.interval <= 0:
        ap.error("--interval must be a finite positive number")
    if not 0 <= args.health_port <= 65535:
        ap.error("--health-port must be between 0 and 65535")

    health = None
    if args.watch:
        try:
            health = ThreadingHTTPServer(("0.0.0.0", args.health_port), HealthHandler)
        except (OSError, ValueError) as e:
            print(f"[router] health startup failed: {e}", file=sys.stderr)
            return 1
        health.routes_count = None
        threading.Thread(target=health.serve_forever, daemon=True).start()

    def once(force_reload=False):
        settings, routes = parse_routes(args.routes)
        settings = apply_env(settings)
        content = render(settings, routes)
        changed = not content_matches(args.out, content)
        # Bootstrap only in watch mode: Caddy needs a file before it can start.
        if args.watch and not os.path.exists(args.out):
            write_if_changed(args.out, content)
            print(f"[router] bootstrapped {args.out}; waiting for Caddy", flush=True)
        # Health must not depend on Caddy: deploy waits for router before starting Caddy.
        if health is not None and health.routes_count is None:
            health.routes_count = len(routes)
        if args.admin and (changed or force_reload):
            st = reload_caddy(content, args.admin)
            print(f"[router] caddy reload -> {st}", flush=True)
        if write_if_changed(args.out, content):
            print(f"[router] rendered {args.out} ({len(routes)} routes)")
        if health is not None:
            health.routes_count = len(routes)

    if not args.watch:
        try:
            once(force_reload=True)
        except (OSError, RuntimeError, ValueError) as e:
            print(f"[router] update failed: {e}; previous Caddyfile preserved", file=sys.stderr)
            return 1
        return 0

    last = None
    while True:
        try:
            stat = os.stat(args.routes)
            m = (stat.st_mtime_ns, stat.st_size, stat.st_ino)
            if m != last:
                once(force_reload=last is None)
                last = m
        except (OSError, RuntimeError, ValueError) as e:
            print(f"[router] watch error: {e}; will retry", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
