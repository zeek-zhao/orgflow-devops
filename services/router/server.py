#!/usr/bin/env python3
"""Router —— routes.yaml 渲染 + Caddy admin reload（零第三方依赖）。

拍定决策（orgflow-AI-提示词-最终版 P1）：
  router 只渲染「路径型」配置（handle_path prefix → upstream + strip），
  禁止生成 Host 型 vhost；render 输出 == Caddy 实跑配置。

修复轮 T1（安全收口）：
  - POST /render 仅允许容器内本机（127.0.0.1/::1）；公网由 Caddy @render 403 兜底。
  - 被拒来源 IP 打到 stdout（docker logs 可见）。
  - GET /render 仍 405（不放宽为可用）。
  - GET /routes 展示层脱敏：去 admin IP 与 /ca/ 证书绝对路径（下发实跑配置不脱敏）。
  - 新增 CLI 入口 `python3 /app/server.py --render`，供容器内本机触发（容器无 curl）。

设计：render() 生成一份**完整且自洽的 Caddyfile**（admin 内网绑定 / :80 跳转 /
  内网站点 / 公网入口块），routes.yaml 的动态前缀注入公网入口块。
  /render 流程：load → render 完整配置 → POST /load（Content-Type: text/caddyfile，
  对齐 main render.py；Caddy 内置 adapter 即 validate，语法错返回 422 不 reload）
  → 幂等跳过。下发的是 render 原文，故输出 == 实跑配置。

端点：
  GET  /healthz  → 200
  GET  /routes   → 脱敏后的路径型 Caddyfile（展示用，去内网 IP 与证书路径）
  POST /render   → 仅本机；见上；坏 prefix/upstream 或 caddy validate 失败 → 422；
                   非本机 → 403；Caddy 不可达 → 503
CLI：
  python3 /app/server.py --render  → 容器内本机触发 reload（容器无 curl 时的正式入口）

依赖：对齐 main render.py「零第三方依赖」，本服务跑 main 的 router:24.04-v1
镜像（内含 python3，无 PyYAML），routes.yaml 用极简 schema 手写解析。
"""
import hashlib
import html
import json
import os
import re
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES = os.environ.get("ROUTES", "/etc/router/routes.yaml")
CADDY_ADMIN = os.environ.get("CADDY_ADMIN", "http://192.168.90.10:2019")
DOMAIN = os.environ.get("DOMAIN", os.environ.get("GATEWAY_DOMAIN", "org-devops.com")).strip().strip(".")
PUBLIC_PORT = os.environ.get("PUBLIC_PORT", "18081").strip()
CADDY_IP = os.environ.get("IP_CADDY", "192.168.90.10").strip()
# T1：仅这些来源可触发 POST /render（容器内本机回环）
ALLOW = {"127.0.0.1", "::1"}
PREFIX_RE = re.compile(r"^/(?:[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*)?$")
UPSTREAM_RE = re.compile(r"^[a-zA-Z0-9_.-]+:\d+$")

_last_hash = None

# T4/T6：/status HTML 说明页（与 config/Caddyfile 内联 HTML 同源；render 输出 == 实跑）
STATUS_HTML = (
    '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<title>OrgFlow 服务状态</title>'
    '<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#1b2430}'
    'h1{font-size:1.4rem}table{border-collapse:collapse;width:100%}th,td{border:1px solid #d8dee9;padding:.5rem .7rem;text-align:left}'
    'th{background:#f2f5f9}code{background:#eef2f7;padding:.1rem .35rem;border-radius:4px}'
    '.note{margin-top:1.2rem;color:#556}</style></head><body>'
    '<h1>OrgFlow 底座 · 服务状态</h1>'
    '<p>本页是 7 个服务的状态说明。各服务入口与探测方式如下（DNS / LDAP / Caddy 无独立 Web UI，状态见<a href="/">首页卡片</a>）。</p>'
    '<table><thead><tr><th>服务</th><th>探测方式</th><th>公网入口</th></tr></thead><tbody>'
    '<tr><td>统一面板 homepage</td><td>HTTP 根路径 /</td><td><a href="/">/</a></td></tr>'
    '<tr><td>LDAP 管理 ldapadmin</td><td>HTTP /ldapadmin/</td><td><a href="/ldapadmin/">/ldapadmin/</a></td></tr>'
    '<tr><td>路由注册 router</td><td>HTTP /router/healthz</td><td><a href="/router/healthz">/router/healthz</a></td></tr>'
    '<tr><td>DNS 解析 dnsmasq</td><td>ICMP 探容器 + dig</td><td>无 UI，见首页卡片</td></tr>'
    '<tr><td>身份目录 ldap</td><td>ldapsearch 探 389</td><td>无 UI，见首页卡片</td></tr>'
    '<tr><td>Caddy 网关 caddy</td><td>admin /config/ 探活</td><td>无 UI，见首页卡片</td></tr>'
    '<tr><td>证书初始化 certs-init</td><td>一次性任务 exit 0</td><td>不放假页面</td></tr>'
    '</tbody></table>'
    '<p class="note">健康探针：<code>/healthz</code>（纯文本 ok）。配置渲染仅允许容器内本机调用，公网 <code>/router/render</code> 返回 403。</p>'
    '</body></html>'
)

# T4：4 条 308 跳转 + /status HTML（render 输出片段，与 config/Caddyfile 公网块一致）
PUBLIC_FIXED = """    @status path /status
    handle @status {
        header Content-Type "text/html; charset=utf-8"
        respond `STATUS_HTML_PLACEHOLDER` 200
    }

    @rootHome path /home /home/*
    handle @rootHome {
        redir https://{host}/ 308
    }
    @noSlashLdap path /ldapadmin
    handle @noSlashLdap {
        redir https://{host}/ldapadmin/ 308
    }
    @routerBare path /router
    handle @routerBare {
        redir https://{host}/router/healthz 308
    }
    @caddyLegacy path /caddy /caddy/*
    handle @caddyLegacy {
        redir https://{host}/status 308
    }
"""


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

    与 config/Caddyfile 结构一致：admin 内网绑定 / :80 跳转 /
    公网入口块（固定片段 status+跳转 + 动态路由注入）。
    T6：不再生成任何 Host 型子域 TLS 站点（home./ldapadmin./router. 已删），
    只输出 admin + :80 + :PUBLIC_PORT 骨架，杜绝与实跑配置形成第二份真源。
    根 prefix=/ → 直接反代不 strip；其余 /x → handle_path /x/* strip。
    不含 Host 型站点覆盖公网，杜绝与实跑漂移（拍定 P1）。
    T1：公网块顶部加 @render 403（与 config/Caddyfile 静态挂载一致），
    必须排在 handle_path /router/* 之前，防止 reload 后公网又能触发渲染。
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
    # T1：公网 POST /render 兜底拒绝（Caddy 按顺序匹配，必须先于 /router/*）
    render_guard = (
        "    @render path /router/render\n"
        "    handle @render {\n"
        "        respond 403\n"
        "    }"
    )

    # T6：公网固定片段（status HTML + 4 跳转）用真实 HTML 替换占位符
    public_fixed = PUBLIC_FIXED.replace("STATUS_HTML_PLACEHOLDER", STATUS_HTML)

    return f"""# 由 router /render 生成的完整路径型 Caddyfile（== 实跑配置）
{{
    admin {CADDY_IP}:2019
}}

:80 {{
    redir https://{{host}}{{uri}} permanent
}}

:{PUBLIC_PORT} {{
    @healthz path /healthz
    handle @healthz {{
        respond "ok" 200
    }}

{public_fixed}
{render_guard}

{dyn_block}

{root_block}
}}
"""


def sanitize_for_display(text):
    """T1（§2.3）：GET /routes 展示层脱敏，去掉内网 admin IP 与 /ca/ 证书绝对路径。
    仅作用于展示输出；POST /render 下发给 Caddy 的实跑配置不经过此函数。"""
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        indent = line[: len(line) - len(line.lstrip())]
        if stripped.startswith("admin ") and ":2019" in stripped:
            out.append(indent + "# admin: 仅内网（展示已脱敏）")
        elif stripped.startswith("tls /ca/"):
            out.append(indent + "# tls: 证书由 CA 卷提供（展示已脱敏）")
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def reload_caddy(caddyfile_text):
    """Caddy /load：以 text/caddyfile 下发原始 Caddyfile（对齐 main render.py）。
    Caddy 内置 caddyfile adapter 解析；语法错误返回 400。
    返回 (status, msg)；status 422 表示配置校验失败（调用方据此不更新状态）。"""
    import urllib.error
    req = urllib.request.Request(
        f"{CADDY_ADMIN}/load", data=caddyfile_text.encode("utf-8"),
        headers={"Content-Type": "text/caddyfile"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status, "ok"
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace").strip()[:400]
        if 400 <= e.code < 500:
            return 422, f"caddy validate 失败: {detail}"
        return e.code, detail
    except Exception as e:
        return 503, f"caddy 不可达: {e}"


def do_render():
    """执行渲染流程（HTTP POST 与 CLI --render 共用）。
    返回 (http_code, message)，与调用方无关。"""
    global _last_hash
    try:
        routes = load_routes()
    except ValueError as e:
        return 422, f"拒绝 reload（坏 prefix/upstream）: {html.escape(str(e))}"
    config_text = render(routes)
    h = hashlib.sha256(config_text.encode()).hexdigest()
    if h == _last_hash:
        return 200, "幂等：配置未变，跳过 reload"
    status, rmsg = reload_caddy(config_text)
    if status == 422:
        return 422, f"拒绝 reload（caddy validate 失败）: {html.escape(rmsg)}"
    if status >= 500:
        return 503, rmsg
    _last_hash = h
    return 200, f"reload ok（{len(routes)} 条路径路由，validate 通过，输出==实跑）"


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
                # T1：展示层脱敏，去内网 IP 与证书路径（下发实跑配置不受影响）
                self._send(200, sanitize_for_display(render(load_routes())))
            except ValueError as e:
                self._send(422, f"配置错误: {html.escape(str(e))}")
            return
        if self.path == "/render":
            # T1：GET 不得因放宽变成可用
            self._send(405, "method not allowed"); return
        self._send(404, "not found")

    def do_POST(self):
        # T1：来源校验，仅容器内本机可触发渲染
        if self.path != "/render":
            self._send(404, "not found"); return
        client_ip = self.client_address[0]
        if client_ip not in ALLOW:
            print(f"[render] DENY 来源 {client_ip} 访问 POST /render", flush=True)
            self._send(403, "render 仅允许容器内本机调用"); return
        code, msg = do_render()
        self._send(code, msg)

    def log_message(self, *args):
        pass


def cli_render():
    """T1 CLI 入口：容器内本机触发渲染（容器无 curl 时的正式入口）。"""
    code, msg = do_render()
    stream = sys.stdout if code < 400 else sys.stderr
    print(f"[render] {code}: {msg}", file=stream, flush=True)
    return 0 if code < 400 else 1


if __name__ == "__main__":
    if "--render" in sys.argv:
        sys.exit(cli_render())
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
