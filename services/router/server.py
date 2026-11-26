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
CADDY_ADMIN = os.environ.get("CADDY_ADMIN", "http://192.168.90.10:2019")  # 0.0.0.0:2019 含 .10，故这里用 .10 访问 admin 仍成立
DOMAIN = os.environ.get("DOMAIN", os.environ.get("GATEWAY_DOMAIN", "org-devops.com")).strip().strip(".")
PUBLIC_PORT = os.environ.get("PUBLIC_PORT", "18081").strip()
CADDY_IP = os.environ.get("IP_CADDY", "192.168.90.10").strip()
# T1：仅这些来源可触发 POST /render（容器内本机回环）
ALLOW = {"127.0.0.1", "::1"}
PREFIX_RE = re.compile(r"^/(?:[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*)?$")
UPSTREAM_RE = re.compile(r"^[a-zA-Z0-9_.-]+:\d+$")

_last_hash = None

# r5 §4-8：/status HTML 说明页的唯一真源。Caddy 的 @status 改为 reverse_proxy router:8080，
# 本文件 GET /status 直接返回动态生成的 HTML；config/Caddyfile 不再内联第二份，消除双写漂移。
# M2.1 复核：服务清单改为从 services/manifest.tsv 动态读取（与主页/服务清单同源），
# 不再写死 9 行——新增服务（含 gerrit/cgit）自动进状态页，判据 `grep -c 'of-*'` 随之变化。
# 每行一个 <code><prefix>-<svc></code>，带 Status-Source: router 头供公网侧判定来源。
MANIFEST_PATH = os.environ.get("MANIFEST", "/etc/router/manifest.tsv")
CONTAINER_PREFIX = os.environ.get("CONTAINER_PREFIX", "of")

# M2.4 Phase2：Gerrit 公网入口（:8443）从 URL_GERRIT 环境变量读取，域名不写死；
# 未注入时回退到首页卡文案（首页 Gerrit 卡本身链到 :8443），保证可达性。
import html as _html
_URL_GERRIT = os.environ.get("URL_GERRIT", "").strip()
GERRIT_ENTRY_HTML = (
    f'<a href="{_html.escape(_URL_GERRIT)}" rel="noopener">代码评审入口 (:8443)</a>'
    if _URL_GERRIT else "见首页 Gerrit 入口卡（:8443）"
)

# 展示元数据（探测方式 / 公网入口 HTML）：服务清单来自 manifest，这里只给展示文案。
# 新增服务若在表里没有条目，用通用回退文案，不会漏行。
STATUS_META = {
    "homepage":       ("统一面板", "HTTP 根路径 /", '<a href="/">/</a>'),
    "ldapadmin":      ("LDAP 管理", "HTTP /ldapadmin/", '<a href="/ldapadmin/">/ldapadmin/</a>'),
    "router":         ("路由注册", "HTTP /router/healthz", '<a href="/router/healthz">/router/healthz</a>'),
    "dnsmasq":        ("DNS 解析", "ICMP 探容器 + dig", "无 UI，见首页卡片"),
    "ldap":           ("身份目录", "ldapsearch 探 389", "无 UI，见首页卡片"),
    "caddy":          ("Caddy 网关", "admin /config/ 探活", "无 UI，见首页卡片"),
    "certs-init":     ("证书初始化", "一次性任务 exit 0", "不放假页面"),
    "jenkins":        ("持续集成 Jenkins", "HTTP /jenkins/login", '<a href="/jenkins/">/jenkins/</a>（需登录）'),
    "jenkins-agent":  ("构建节点 Jenkins Agent", "SSH 22 / Job 在线探测", "无 UI，见首页卡片"),
    # M2.4 Phase2：Gerrit 行直接链到 URL_GERRIT（:8443），域名走配置项不写死；未注入时回退首页卡文案。
    "gerrit":         ("代码评审 Gerrit", "HTTP :8443/ + LDAP 登录", GERRIT_ENTRY_HTML),
    "cgit":           ("代码浏览 cgit", "HTTP /cgit/", '<a href="/cgit/">/cgit/</a>'),
    "registry":       ("镜像仓库 registry", "HTTP :5000/v2/（401 鉴权生效）", "API only · 公网 :10000 / 内网 :18086"),
    # M2.3 收口 P2-2：builder 无 Web UI，也不在首页渲染卡片（manifest public_path=/none），
    # 状态页给出真实探测方式与内网入口，避免"入口见首页卡片 / 首页指向状态页"互相推诿。
    "builder":        ("构建器 BuildKit builder", "容器内 buildctl debug workers", "tcp://builder:1234（仅内网，无 Web UI）"),
}


def status_rows():
    """从 manifest.tsv 读服务清单（order 排序）；读不到时返回空，由调用方回退。"""
    import csv
    with open(MANIFEST_PATH, encoding="utf-8-sig") as f:
        rows = [r for r in csv.DictReader(f, delimiter="\t") if (r.get("service") or "").strip()]
    rows.sort(key=lambda r: int(r.get("order", 0)))
    return rows


def build_status_html():
    """按 manifest 动态生成状态页；manifest 不可读时回退到已知服务全集（不假绿）。"""
    try:
        rows = status_rows()
        svcs = [r["service"] for r in rows]
    except (OSError, ValueError, TypeError):
        svcs = list(STATUS_META.keys())
    n = len(svcs)
    tr = []
    for svc in svcs:
        label, probe, entry = STATUS_META.get(svc, (svc, "见首页卡片", "见首页卡片"))
        tr.append(f'<tr><td>{html.escape(label)} {html.escape(svc)}</td>'
                  f'<td><code>{html.escape(CONTAINER_PREFIX)}-{html.escape(svc)}</code></td>'
                  f'<td>{probe}</td><td>{entry}</td></tr>\n')
    return (
        '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>OrgFlow 服务状态</title>'
        '<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#1b2430}'
        'h1{font-size:1.4rem}table{border-collapse:collapse;width:100%}th,td{border:1px solid #d8dee9;padding:.5rem .7rem;text-align:left}'
        'th{background:#f2f5f9}code{background:#eef2f7;padding:.1rem .35rem;border-radius:4px}'
        '.note{margin-top:1.2rem;color:#556}</style></head><body>'
        '<h1>OrgFlow 底座 · 服务状态</h1>'
        '<p class="note"><a href="/reports/selfcheck/latest.html">自检报告（最新）</a> · '
        '<a href="/">返回首页</a></p>'
        f'<p>本页是 {n} 个服务的状态说明（来源 <code>router</code>，清单取自 <code>manifest.tsv</code>）。'
        '各服务入口与探测方式如下（DNS / LDAP / Caddy / Jenkins Agent 无独立 Web UI，状态见<a href="/">首页卡片</a>）。</p>'
        '<table><thead><tr><th>服务</th><th>容器</th><th>探测方式</th><th>公网入口</th></tr></thead><tbody>\n'
        + "".join(tr) +
        '</tbody></table>'
        '<p class="note">健康探针：<code>/healthz</code>（纯文本 ok）。配置渲染仅允许容器内本机调用，公网 <code>/router/render</code> 返回 403。</p>'
        '</body></html>'
    )


# M2.2 第五回复核 P1-1：去掉模块级启动快照。manifest 经 bind mount 挂载，容器不重建
# 时 STATUS_HTML 永远停在启动那刻的服务数（如 11）。改为请求时按 manifest mtime 缓存：
# 文件变了才重建，兼顾实时性与零开销（stat 一次极廉价）。
_status_cache = {"mtime": None, "html": None}


def get_status_html():
    try:
        mtime = os.stat(MANIFEST_PATH).st_mtime
    except OSError:
        mtime = None
    if _status_cache["html"] is None or _status_cache["mtime"] != mtime:
        _status_cache["html"] = build_status_html()
        _status_cache["mtime"] = mtime
    return _status_cache["html"]


# r5 §4-8：4 条 308 跳转 + /status 反代（HTML 由 router GET /status 唯一提供，不再内联）
PUBLIC_FIXED = """    @status path /status
    handle @status {
        reverse_proxy router:8080
    }

    # M2.4 Phase3：自检报告（共享卷 ro /srv/reports），no-store + 静态文件服务。
    handle_path /reports/* {
        root * /srv/reports
        header Cache-Control "no-store"
        file_server
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
    # T9(P0)：/router/ strip 成 / 致 router(BaseHTTP) 404，先于 handle_path 拦截 308
    @routerRoot path /router/
    handle @routerRoot {
        redir https://{host}/router/healthz 308
    }
    @caddyLegacy path /caddy /caddy/*
    handle @caddyLegacy {
        redir https://{host}/status 308
    }
    # M1：/jenkins 无斜杠 → 308 到 /jenkins/（Jenkins 自带 --prefix=/jenkins，
    # 由 strip:false 的 handle 保留前缀反代，不能用 handle_path 剥前缀）。
    @jenkinsBare path /jenkins
    handle @jenkinsBare {
        redir https://{host}/jenkins/ 308
    }

    # R1(P1) 公网信息泄漏收口（与 config/Caddyfile 同步，render 输出 == 实跑）。
    # 实测 remote_ip 方案失效（公网经 Funnel、容器内经网桥，.remote.host 同为 192.168.90.1），
    # 改用「仅允许内网 Host 头」：放行 {$DOMAIN} 与 192.168.90.x，其余（含公网域名）403。
    # 域名走 {$DOMAIN} 占位符不写死；服务间直连 homepage:3000 不受影响；首页 12 卡为 SSR。
    @homeApi path /api/services /api/widgets
    handle @homeApi {
        @fromLan host {$DOMAIN} ^192[.]168[.]90[.][0-9]+$
        handle @fromLan {
            reverse_proxy homepage:3000
        }
        respond 403
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
        # M1：可选 strip 字段（缺省 true 保持既有 handle_path 行为）；只允许 true/false
        if "strip" in r and str(r["strip"]).lower() not in ("true", "false"):
            raise ValueError(f"非法 strip: {r['strip']}（只允许 true/false）")
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
        # M1：strip:false → handle 保留原始路径（Jenkins --prefix=/jenkins 需完整路径，
        # 用 handle_path 会剥掉 /jenkins 致 404）；缺省 true 保持既有 handle_path。
        strip = str(r.get("strip", "true")).lower()
        if strip == "false":
            # T6：与 config/Caddyfile 的 /jenkins/* 块一致，回写 https scheme/Host，
            # 避免 Funnel→Caddy 的 http 让 Jenkins 生成 http:// 外链。
            dyn.append(f"    # {prefix} 保留前缀（strip:false），上游自带 prefix\n"
                       f"    handle {prefix}/* {{\n"
                       f"        reverse_proxy {up} {{\n"
                       f"            header_up X-Forwarded-Proto https\n"
                       f"            header_up X-Forwarded-Host {{host}}\n"
                       f"        }}\n"
                       f"    }}")
        else:
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

    # r5 §4-8：/status 已改 reverse_proxy router:8080，无需再内联替换 HTML 占位符。
    public_fixed = PUBLIC_FIXED

    return f"""# 由 router /render 生成的完整路径型 Caddyfile（== 实跑配置）
{{
    # M1 收口 T3：管理口绑 0.0.0.0:2019（宿主端口映射限 127.0.0.1，外部不可达）
    admin 0.0.0.0:2019
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
    def _send(self, code, text, content_type="text/plain; charset=utf-8", extra_headers=None):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        # 判据 7：curl -sI 走 HEAD；与 GET /status 同状态/同头，无 body。
        if self.path == "/status":
            print(f"[status] HEAD /status from {self.client_address[0]}", flush=True)
            self._send(200, "", content_type="text/html; charset=utf-8",
                       extra_headers={"Status-Source": "router"}); return
        if self.path == "/healthz":
            self._send(200, ""); return
        self._send(404, "")

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, "ok"); return
        if self.path == "/status":
            # r5 §4-8：状态页唯一真源（文本 HTML；Caddy @status reverse_proxy 到此）。
            # M2.2 P1-1：改为 get_status_html()（按 manifest mtime 缓存），新增服务实时进页面。
            print(f"[status] GET /status from {self.client_address[0]}", flush=True)
            self._send(200, get_status_html(), content_type="text/html; charset=utf-8",
                       extra_headers={"Status-Source": "router"}); return
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
