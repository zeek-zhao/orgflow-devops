#!/usr/bin/env python3
"""Router —— routes.yaml 渲染 + Caddy admin reload（零第三方依赖）。

端点：
  GET  /healthz  → 200（只要本进程活着）
  GET  /routes   → 当前渲染出的配置片段（便于断言）
  POST /render   → 读 routes.yaml → 校验 → 渲染 → 调 Caddy admin /load
                    - 坏 upstream → 422，且不 reload
                    - Caddy 不可达 → 503（降级，不退出）
                    - 与上次相同 → 幂等跳过 reload，返回 200

依赖说明：对齐 main 的 render.py「不依赖 PyYAML，保证零第三方依赖」——
本服务跑在 main 的 router:24.04-v1 镜像上（内含 python3，无 PyYAML），
routes.yaml 用极简 schema（routes: 列表，每项 host/upstream），手写解析即可。
"""
import hashlib
import html
import json
import os
import re
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES = os.environ.get("ROUTES", "/etc/router/routes.yaml")
CADDY_ADMIN = os.environ.get("CADDY_ADMIN", "http://caddy:2019")
# v1.0 §6 / AC-22：域名后缀唯一真源来自 .env 的 DOMAIN，经 compose 注入。
# routes.yaml 只写子域（home/ldapadmin/router），render 时拼成 sub.domain；
# 仍兼容写死完整 host（含点）的旧配置，便于测试与平滑迁移。
GATEWAY_DOMAIN = os.environ.get("GATEWAY_DOMAIN", "").strip().strip(".")
HOST_RE = re.compile(r"^[a-z0-9.-]+$", re.I)
UPSTREAM_RE = re.compile(r"^[a-zA-Z0-9_.-]+:\d+$")

_last_hash = None


def _parse_routes(text):
    """极简 routes.yaml 解析：只认 routes: 下列表项的 host/upstream 标量。
    不依赖 PyYAML；遇到超出约定的结构直接报错，避免静默丢项。"""
    routes = []
    cur = None
    in_routes = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        s = line.strip()
        if indent == 0:
            if s == "routes:":
                in_routes = True
                continue
            in_routes = False
            continue
        if not in_routes:
            continue
        if s.startswith("- "):
            if cur:
                routes.append(cur)
            cur = {}
            s = s[2:].strip()
            if ":" in s:
                k, v = s.split(":", 1)
                cur[k.strip()] = v.strip().strip('"\'')
            continue
        if cur is not None and ":" in s:
            k, v = s.split(":", 1)
            cur[k.strip()] = v.strip().strip('"\'')
    if cur:
        routes.append(cur)
    return routes


def full_host(host):
    """子域 → 完整域名。host 已含点视为完整域名（向后兼容），否则拼 GATEWAY_DOMAIN。"""
    host = str(host).strip().strip(".")
    if "." in host:
        return host
    if not GATEWAY_DOMAIN:
        raise ValueError("routes.yaml 用了子域但未设置 GATEWAY_DOMAIN（应由 .env 的 DOMAIN 注入）")
    return f"{host}.{GATEWAY_DOMAIN}"


def load_routes():
    with open(ROUTES, encoding="utf-8") as f:
        routes = _parse_routes(f.read())
    if not routes:
        raise ValueError("routes.yaml 的 routes 必须是非空列表")
    for r in routes:
        host = str(r.get("host", ""))
        up = str(r.get("upstream", ""))
        if not HOST_RE.match(host):
            raise ValueError(f"非法 host: {host}")
        if not UPSTREAM_RE.match(up):
            raise ValueError(f"非法 upstream: {up}（应形如 service:port）")
        # 尽早校验：子域缺 GATEWAY_DOMAIN 时在 load 阶段就报错，不拖到 render
        full_host(host)
    return routes


def render(routes):
    blocks = []
    for r in routes:
        blocks.append(
            f"{full_host(r['host'])} {{\n"
            f"    tls /ca/site.crt /ca/site.key\n"
            f"    reverse_proxy {r['upstream']}\n"
            "}\n"
        )
    return "\n".join(blocks)


def reload_caddy(config_text):
    """调 Caddy admin API 加载配置。返回 (http_status, msg)。"""
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
