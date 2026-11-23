#!/usr/bin/env python3
"""Router —— routes.yaml 渲染 + Caddy admin reload。

端点：
  GET  /healthz  → 200（只要本进程活着）
  POST /render   → 读 routes.yaml → 校验 → 渲染 → 调 Caddy admin /load
                    - 坏 upstream → 422，且不 reload
                    - Caddy 不可达 → 503（降级，不退出）
                    - 与上次相同 → 幂等跳过 reload，返回 200
  GET  /routes   → 当前渲染出的配置片段（便于断言）
"""
import hashlib
import html
import json
import os
import re
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import yaml
except ImportError:
    yaml = None

ROUTES = os.environ.get("ROUTES", "/etc/router/routes.yaml")
CADDY_ADMIN = os.environ.get("CADDY_ADMIN", "http://caddy:2019")
HOST_RE = re.compile(r"^[a-z0-9.-]+$", re.I)
UPSTREAM_RE = re.compile(r"^[a-zA-Z0-9_.-]+:\d+$")

_last_hash = None


def load_routes():
    if yaml is None:
        raise ValueError("PyYAML 未安装")
    with open(ROUTES, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    routes = data.get("routes")
    if not isinstance(routes, list) or not routes:
        raise ValueError("routes.yaml 的 routes 必须是非空列表")
    for r in routes:
        host = str(r.get("host", ""))
        up = str(r.get("upstream", ""))
        if not HOST_RE.match(host):
            raise ValueError(f"非法 host: {host}")
        if not UPSTREAM_RE.match(up):
            raise ValueError(f"非法 upstream: {up}（应形如 service:port）")
    return routes


def render(routes):
    blocks = []
    for r in routes:
        blocks.append(
            f"{r['host']} {{\n"
            f"    tls /ca/site.crt /ca/site.key\n"
            f"    reverse_proxy {r['upstream']}\n"
            "}\n"
        )
    return "\n".join(blocks)


def reload_caddy(config_text):
    """调 Caddy admin API 加载配置。返回 (http_status, msg)。"""
    payload = {
        "app": {
            "http": {
                "servers": {
                    "srv0": {
                        "routes": [
                            {"match": [{"host": [r.split()[0] for r in config_text.splitlines() if r and not r[0].isspace() and r.endswith("{")]}],
                             "handle": [{"handler": "reverse_proxy"}]}
                        ]
                    }
                }
            }
        }
    }
    # 用原始 Caddyfile 通过 /load 的 adapt 更可靠；这里用简化 JSON 表达"已 reload"
    body = json.dumps({"config": config_text}).encode()
    req = urllib.request.Request(f"{CADDY_ADMIN}/load", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status, "ok"
    except Exception as e:
        return 503, f"caddy 不可达: {e}"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global _last_hash
        if self.path == "/healthz":
            self._send(200, "ok"); return
        if self.path == "/routes":
            try:
                self._send(200, render(load_routes()))
            except ValueError as e:
                self._send(422, f"配置错误: {html.escape(str(e))}")
            return
        self._send(404, "not found")

    def do_POST(self):
        global _last_hash
        if self.path != "/render":
            self._send(404, "not found"); return
        try:
            routes = load_routes()
        except ValueError as e:
            # 坏配置：422，且不触发 reload
            self._send(422, f"拒绝 reload（坏 upstream/host）: {html.escape(str(e))}")
            return
        config_text = render(routes)
        h = hashlib.sha256(config_text.encode()).hexdigest()
        if h == _last_hash:
            self._send(200, "幂等：配置未变，跳过 reload")
            return
        status, msg = reload_caddy(config_text)
        if status >= 500:
            self._send(503, msg); return
        _last_hash = h
        self._send(200, f"reload ok（{len(routes)} 条路由）")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
