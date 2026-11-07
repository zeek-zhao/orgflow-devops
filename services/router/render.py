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
NAME_RE = SUBDOMAIN_RE
# 注册 API 写 routes.yaml；routes.yaml 仍是唯一真源，API 只是它的写入口。
CA_CERT_NAME = "root.crt"
CA_SCRIPT_NAME = "ca-install.sh"


def _value(s, key):
    return s.split(":", 1)[1].strip().strip('"').strip("'")


def parse_routes_text(text):
    """解析极简 YAML：顶层键 + routes 列表。返回 (settings, routes)。"""
    settings = {"gateway_domain": DEFAULT_DOMAIN}
    routes = []
    cur = None
    for raw in text.splitlines():
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


def parse_routes(path):
    with open(path, "r", encoding="utf-8") as f:
        return parse_routes_text(f.read())


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

        # docs 特例(#86/#88):唯一受网关保护的站点。Caddy file_server 直接服务
        # 静态文档(容器挂载 docs/ → /srv/docs),/oauth2/* 走 oauth2-proxy——
        # 登录与回调都在 docs 域闭环,cookie 落在 docs 单域,不跨域。
        if (r.get("name") or "").strip() == "docs":
            out.append(f"https://docs.{domain} {{")
            out.extend([
                # 匹配器豁免 /oauth2/*:start/callback 若也被 forward_auth 拦下,
                # 会 302 到自身造成 rd 无限增长(实测踩过)
                "\t@notoauth2 not path /oauth2/*",
                "\tforward_auth @notoauth2 oauth2-proxy:4180 {",
                "\t\turi /oauth2/auth",
                "\t\tcopy_headers X-Auth-Request-User X-Auth-Request-Email",
                "\t\t@unauth status 401",
                "\t\thandle_response @unauth {",
                f"\t\t\tredir * https://docs.{domain}/oauth2/start"
                "?rd={scheme}://{host}{uri} 302",
                "\t\t}",
                "\t}",
                "\thandle /oauth2/* {",
                "\t\treverse_proxy oauth2-proxy:4180",
                "\t}",
                "\thandle {",
                "\t\troot * /srv/docs",
                "\t\tfile_server",
                "\t}",
                "}",
                "",
            ])
            continue

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


def validate_route(payload, existing, gateway_domain):
    """校验并规范化一条新路由（#61）。非法抛 ValueError；返回规范化 dict。

    subdomain 可直接给，也可以给 host（FQDN，带 .<gateway_domain> 后缀时剥掉）。
    """
    if not isinstance(payload, dict):
        raise ValueError("route must be a JSON object")
    name = str(payload.get("name", "")).strip()
    if not NAME_RE.match(name):
        raise ValueError("name 必须为非空小写字母/数字/连字符")
    sub = str(payload.get("subdomain", "")).strip().strip(".")
    if not sub:
        host = str(payload.get("host", "")).strip().strip(".")
        if not host:
            raise ValueError("subdomain is required (或提供 host)")
        suffix = f".{gateway_domain}"
        sub = host[: -len(suffix)] if host.endswith(suffix) else host
    if not SUBDOMAIN_RE.match(sub):
        raise ValueError(f"subdomain {sub!r}: 只允许小写字母/数字/连字符")
    if sub == gateway_domain:
        raise ValueError(f"subdomain {sub!r} 不能是网关域名本身")
    for r in existing:
        if (r.get("subdomain") or "").strip() == sub:
            raise ValueError(f"route {sub}: duplicate subdomain")
        if (r.get("name") or "").strip() == name:
            raise ValueError(f"route {name}: duplicate name")
    upstream = str(payload.get("upstream", "")).strip()
    if not upstream:
        raise ValueError("upstream is required")
    return {
        "name": name,
        "subdomain": sub,
        "upstream": upstream,
        "auth": bool(payload.get("auth", False)),
    }


def _serialize_route_block(route):
    lines = [f"  - name: {route['name']}", f"    subdomain: {route['subdomain']}",
             f"    upstream: {route['upstream']}"]
    if route.get("auth"):
        lines.append("    auth: true")
    return "\n".join(lines) + "\n"


def _write_routes_validated(path, new_text):
    """先按「改完的文本」完整走一遍 parse+render，全绿才落盘。

    这是 400 反证（文件 sha256 不变）的保证：非法输入在写之前就被拒绝。
    """
    settings, routes = parse_routes_text(new_text)
    render(apply_env(settings), routes)
    write_if_changed(path, new_text)


def append_route(path, route):
    """把一条已校验的路由追加到 routes.yaml 末尾（routes 列表是文件最后一段）。"""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    _write_routes_validated(path, text.rstrip("\n") + "\n" + _serialize_route_block(route))


def delete_route(path, name):
    """按 name 从 routes.yaml 删除一个条目块；注释与其他条目原样保留。"""
    if name == AUTH_ROUTE_NAME:
        raise ValueError(f"route {name}: 认证网关路由不能删除")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    settings, routes = parse_routes_text(text)
    if not any((r.get("name") or "").strip() == name for r in routes):
        raise KeyError(name)
    pattern = re.compile(
        rf"\n  - name: {re.escape(name)}\n(?:    [^\n]*\n)+"
    )
    new_text, n = pattern.subn("\n", text, count=1)
    if n != 1:
        raise ValueError(f"route {name}: 无法在 routes.yaml 中定位条目块")
    _write_routes_validated(path, new_text)


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


class RouterHandler(BaseHTTPRequestHandler):
    """健康检查（/healthz）+ 路由注册 API（#61）+ CA 分发静态文件（#62）。

    鉴权口径（#61 前置项的结论）：**不加鉴权** —— router 只在容器网络内，
    不对外发布端口，与 Caddy admin（caddy:2019）同口径；威胁模型写在
    docs/services/router.md。
    """

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _file(self, filename, content_type):
        path = os.path.join(self.server.ca_dir or "", filename)
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self._json(404, {"error": f"{filename} 不存在；先在网关机跑 make ca / ca-install.sh --export"})
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            ready = self.server.health_state["routes_count"] is not None
            self._json(200 if ready else 503,
                       {"ok": ready, "routes": self.server.health_state["routes_count"] or 0})
        elif self.path == "/routes":
            settings, routes = parse_routes(self.server.routes_path)
            self._json(200, {"gateway_domain": settings["gateway_domain"], "routes": routes})
        elif self.path == f"/{CA_CERT_NAME}":
            self._file(CA_CERT_NAME, "application/x-x509-ca-cert")
        elif self.path == f"/{CA_SCRIPT_NAME}":
            self._file(CA_SCRIPT_NAME, "text/x-shellscript")
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/routes":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._json(400, {"error": "bad Content-Length"})
            return
        if not 0 < length <= 65536:
            self._json(400, {"error": "body 必须是非空 JSON（≤64KB）"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            self._json(400, {"error": f"invalid JSON: {e}"})
            return
        with self.server.route_lock:
            try:
                settings, routes = parse_routes(self.server.routes_path)
                route = validate_route(payload, routes, settings["gateway_domain"])
                append_route(self.server.routes_path, route)
                self.server.once(force_reload=True)
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            except (OSError, RuntimeError) as e:
                self._json(502, {"error": str(e)})
                return
        self._json(201, {"route": route})

    def do_DELETE(self):
        if not self.path.startswith("/routes/"):
            self._json(404, {"error": "not found"})
            return
        name = self.path[len("/routes/"):].strip("/")
        with self.server.route_lock:
            try:
                delete_route(self.server.routes_path, name)
                self.server.once(force_reload=True)
            except KeyError:
                self._json(404, {"error": f"route {name} 不存在"})
                return
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            except (OSError, RuntimeError) as e:
                self._json(502, {"error": str(e)})
                return
        self._json(200, {"deleted": name})

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
    ap.add_argument("--ca-dir", default=os.environ.get("CA_DIR", ""),
                    help="CA 分发目录（含 root.crt / ca-install.sh），为空则不提供下载（#62）")
    args = ap.parse_args()
    if not math.isfinite(args.interval) or args.interval <= 0:
        ap.error("--interval must be a finite positive number")
    if not 0 <= args.health_port <= 65535:
        ap.error("--health-port must be between 0 and 65535")

    # 健康状态单独持有：非 watch 模式没有 HTTP server，once() 也要能跑。
    health_state = {"routes_count": None}

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
        if health_state["routes_count"] is None:
            health_state["routes_count"] = len(routes)
        if args.admin and (changed or force_reload):
            st = reload_caddy(content, args.admin)
            print(f"[router] caddy reload -> {st}", flush=True)
        if write_if_changed(args.out, content):
            print(f"[router] rendered {args.out} ({len(routes)} routes)")
        health_state["routes_count"] = len(routes)

    server = None
    if args.watch:
        try:
            server = ThreadingHTTPServer(("0.0.0.0", args.health_port), RouterHandler)
        except (OSError, ValueError) as e:
            print(f"[router] health startup failed: {e}", file=sys.stderr)
            return 1
        server.routes_count = None
        server.health_state = health_state
        server.routes_path = args.routes
        server.out_path = args.out
        server.admin_url = args.admin
        server.ca_dir = args.ca_dir
        server.route_lock = threading.Lock()
        server.once = once
        threading.Thread(target=server.serve_forever, daemon=True).start()

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
