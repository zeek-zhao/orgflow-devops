#!/usr/bin/env python3
"""Router —— routes.yaml 渲染 + Caddy admin reload（零第三方依赖）。

拍定决策（orgflow-AI-提示词-最终版 P1）：
  router 只渲染「路径型」配置（handle_path prefix → upstream + strip），
  禁止生成 Host 型 vhost；render 输出 == Caddy 实跑配置。

设计：render() 生成一份**完整且自洽的 Caddyfile**（admin 内网绑定 / :80 跳转 /
  内网站点 / 公网入口块），routes.yaml 的动态前缀注入公网入口块。
  /render 流程：load → render 完整配置 → /adapt 校验（失败 422 不 reload）
  → /load 整站替换（加载 adapt 出的 JSON，保证与渲染输出一致）→ 幂等跳过。

端点：
  GET  /healthz  → 200
  GET  /routes   → 渲染出的完整路径型 Caddyfile（便于断言，== 实跑配置）
  POST /render   → 见上；坏 prefix/upstream 或 adapt 失败 → 422；Caddy 不可达 → 503

依赖：对齐 main render.py「零第三方依赖」，本服务跑 main 的 router:24.04-v1
镜像（内含 python3，无 PyYAML），routes.yaml 用极简 schema 手写解析。
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
DOMAIN = os.environ.get("DOMAIN", os.environ.get("GATEWAY_DOMAIN", "org-devops.com")).strip().strip(".")
PUBLIC_PORT = os.environ.get("PUBLIC_PORT", "18081").strip()
CADDY_IP = os.environ.get("IP_CADDY", "192.168.90.10").strip()
PREFIX_RE = re.compile(r"^/(?:[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*)?$")
UPSTREAM_RE = re.compile(r"^[a-zA-Z0-9_.-]+:\d+$")

_last_hash = None


def _parse_routes(text):
    """极简 routes.yaml 解析：只认 routes: 下列表项的 prefix/upstream 标量。
    兼容旧字段 host（视为 prefix）；不依赖 PyYAML；结构越界直接报错。"""
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


def _prefix(r):
    """取路由前缀：新字段 prefix，兼容旧 host（归一为 /<host>）。"""
    p = str(r.get("prefix", r.get("host", ""))).strip()
    if p and not p.startswith("/"):
        p = "/" + p
    return p


def load_routes():
    with open(ROUTES, encoding="utf-8") as f:
        routes = _parse_routes(f.read())
    if not routes:
        raise ValueError("routes.yaml 的 routes 必须是非空列表")
    for r in routes:
        prefix = _prefix(r)
        up = str(r.get("upstream", ""))
        if not PREFIX_RE.match(prefix):
            raise ValueError(f"非法 prefix: {prefix}（应以 / 开头、路径段合法）")
        if not UPSTREAM_RE.match(up):
            raise ValueError(f"非法 upstream: {up}（应形如 service:port）")
    return routes


def render(routes):
    """渲染**完整路径型 Caddyfile**（== 实跑配置）。

    与 config/Caddyfile 结构一致：admin 内网绑定 / :80 跳 :443 /
    三个内网 TLS 站点 / 公网入口块（动态路由注入）。
    根 prefix=/ → 直接反代不 strip；其余 /x → handle_path /x/* strip。
    不含 Host 型站点覆盖公网，杜绝与实跑漂移（拍定 P1）。
    """
    # 公网动态路由片段
    dyn = []
    root_up = None
    for r in routes:
        prefix = _prefix(r)
        up = r["upstream"]
        if prefix == "/":
            root_up = up
            continue
        dyn.append(f"    handle_path {prefix}/* {{\n        reverse_proxy {up}\n    }}")
    dyn_block = "\n\n".join(dyn)
    if root_up is None:
        root_up = "homepage:3000"
    root_block = (
        "    # 根路径：HomePage 唯一门面，直接反代不 strip\n"
        "    handle {\n"
        f"        reverse_proxy {root_up}\n"
        "    }"
    )

    return f"""# 由 router /render 生成的完整路径型 Caddyfile（== 实跑配置）
{{
    admin {CADDY_IP}:2019
}}

:80 {{
    redir https://{{host}}{{uri}} permanent
}}

home.{DOMAIN} {{
    tls /ca/site.crt /ca/site.key
    reverse_proxy homepage:3000
}}

ldapadmin.{DOMAIN} {{
    tls /ca/site.crt /ca/site.key
    reverse_proxy ldapadmin:80
}}

router.{DOMAIN} {{
    tls /ca/site.crt /ca/site.key
    reverse_proxy router:8080
}}

:{PUBLIC_PORT} {{
    @healthz path /healthz
    handle @healthz {{
        respond "ok" 200
    }}

    @status path /status
    handle @status {{
        respond "ok" 200
    }}

{dyn_block}

{root_block}
}}
"""


def _post(path, payload, timeout=5):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{CADDY_ADMIN}{path}", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def adapt(config_text):
    """Caddy /adapt：把 Caddyfile 转 JSON。返回 (ok, body_json_or_error)。"""
    try:
        status, body = _post("/adapt", {"config": config_text, "adapter": "caddyfile"})
        if status >= 400:
            return False, body[:400]
        parsed = json.loads(body)
        if isinstance(parsed, dict) and parsed.get("error"):
            return False, str(parsed["error"])[:400]
        return True, body
    except Exception as e:
        return None, f"adapt 不可达: {e}"


def reload_caddy(json_config):
    """Caddy /load：整站加载 adapt 出的 JSON 配置。返回 (status, msg)。"""
    try:
        req = urllib.request.Request(
            f"{CADDY_ADMIN}/load", data=json.dumps(json_config).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=5) as resp:
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
            self._send(422, f"拒绝 reload（坏 prefix/upstream）: {html.escape(str(e))}")
            return
        config_text = render(routes)
        # /render 前先 caddy validate（经 /adapt），失败 422 且不 reload
        ok, body = adapt(config_text)
        if ok is False:
            self._send(422, f"拒绝 reload（caddy validate 失败）: {html.escape(str(body))}")
            return
        if ok is None:
            self._send(503, str(body)); return
        h = hashlib.sha256(config_text.encode()).hexdigest()
        if h == _last_hash:
            self._send(200, "幂等：配置未变，跳过 reload")
            return
        status, rmsg = reload_caddy(json.loads(body))
        if status >= 500:
            self._send(503, rmsg); return
        _last_hash = h
        self._send(200, f"reload ok（{len(routes)} 条路径路由，validate 通过，输出==实跑）")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
