#!/usr/bin/env python3
"""PublicGateway —— 公网统一入口（配合 Tailscale Funnel）。

Funnel 只暴露一个 *.ts.net 域名，底座各服务又用内网域名/内部 CA，公网无法解析。
本网关跑在宿主机，把单一入口按路径反代到各容器，并提供汇总状态页：

  /                → 状态总览（每个服务的健康 + 公网快捷链接）
  /api/health      → JSON 健康清单（供监控/自检）
  /home/           → homepage   容器 :3000
  /ldapadmin/      → ldapadmin  容器 :8080
  /router/         → router     容器 :8080
  /caddy/          → caddy admin :2019（只读健康用）

设计约束：
- 只用 Python 标准库（宿主机无额外依赖）。
- 后端地址来自 config/defaults.env 里的容器 IP，走 Docker 网桥直达，无需暴露宿主端口。
- 反代用 urllib，逐请求探测；后端不可达返回 502 而非静默丢弃。
"""
import html
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULTS = os.path.join(ROOT, "config", "defaults.env")


def load_defaults():
    """读 config/defaults.env 的 KEY=VALUE（忽略注释/空行）。"""
    cfg = {}
    try:
        with open(DEFAULTS, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    except OSError:
        pass
    return cfg


CFG = load_defaults()


def addr(key, fallback):
    return CFG.get(key, fallback)


# 服务注册表：名称 → (后端 base url, 路径前缀, 说明, 是否 web 可浏览)
SERVICES = [
    ("homepage",  f"http://{addr('IP_HOMEPAGE','192.168.90.11')}:3000",  "/home/",      "统一导航面板", True),
    ("ldapadmin", f"http://{addr('IP_LDAPADMIN','192.168.90.12')}:8080",  "/ldapadmin/", "LDAP 管理页", True),
    ("router",    f"http://{addr('IP_ROUTER','192.168.90.14')}:8080",     "/router/",    "路由状态/热更新", True),
    ("caddy",     f"http://{addr('IP_CADDY','192.168.90.10')}:2019",     "/caddy/",     "反向代理管理", True),
    ("ldap",      f"http://{addr('IP_LDAP','192.168.90.13')}:389",       "",            "目录服务 (389)", False),
    ("dnsmasq",   f"http://{addr('IP_DNSMASQ','192.168.90.15')}:53",     "",            "内网 DNS (53/udp)", False),
]

# 反代路由：路径前缀 → 后端（长前缀优先）
PROXY_ROUTES = sorted([(p, b) for _, b, p, _, web in SERVICES if web and p], key=lambda x: -len(x[0]))


def probe(name, base):
    """探测后端健康。HTTP 服务用 /healthz 或根路径；非 HTTP 服务用 TCP connect。"""
    if name == "ldap":
        import socket
        host = addr("IP_LDAP", "192.168.90.13")
        try:
            s = socket.create_connection((host, 389), timeout=1.5); s.close()
            return True
        except OSError:
            return False
    if name == "dnsmasq":
        import socket
        host = addr("IP_DNSMASQ", "192.168.90.15")
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1.5)
        try:
            s.sendto(b"\x00", (host, 53))
            return True
        except OSError:
            return False
        finally:
            s.close()
    # HTTP 服务
    url = base + ("/healthz" if name == "router" else "/")
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            return r.status < 500
    except urllib.error.HTTPError:
        return True  # 后端活着，只是路径返回非 2xx
    except Exception:
        return False


def health_list():
    return [{"service": n, "healthy": probe(n, b), "path": p, "desc": d}
            for n, b, p, d, _ in SERVICES]


def render_index():
    rows = []
    for item in health_list():
        n, h, p, d = item["service"], item["healthy"], item["path"], item["desc"]
        badge = '<span style="color:#1a7f37">● healthy</span>' if h else '<span style="color:#c0392b">● down</span>'
        link = f'<a href="{html.escape(p)}">{html.escape(p)}</a>' if p else '<span style="color:#888">（内部服务，无 Web）</span>'
        rows.append(f"<tr><td><b>{html.escape(n)}</b></td><td>{badge}</td><td>{link}</td><td>{html.escape(d)}</td></tr>")
    body = "\n".join(rows)
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OrgFlow DevOps · 服务总览</title>
<style>
body{{font-family:system-ui,sans-serif;margin:0;background:#0d1117;color:#e6edf3}}
.wrap{{max-width:860px;margin:2.5rem auto;padding:0 1rem}}
h1{{font-size:1.6rem}} .sub{{color:#8b949e;margin-bottom:1.5rem}}
table{{width:100%;border-collapse:collapse;background:#161b22;border-radius:8px;overflow:hidden}}
th,td{{padding:.7rem .9rem;text-align:left;border-bottom:1px solid #30363d;font-size:.92rem}}
th{{background:#21262d;color:#8b949e}} a{{color:#58a6ff;text-decoration:none}}
a:hover{{text-decoration:underline}} code{{background:#21262d;padding:.1rem .35rem;border-radius:4px}}
</style></head><body><div class="wrap">
<h1>OrgFlow DevOps · 最小底座服务总览</h1>
<div class="sub">公网入口经 Tailscale Funnel → 本网关 → 各容器。健康状态实时探测。</div>
<table><thead><tr><th>服务</th><th>状态</th><th>公网路径</th><th>说明</th></tr></thead>
<tbody>{body}</tbody></table>
<p class="sub" style="margin-top:1.2rem">机器可读取:<a href="/api/health">/api/health</a> ·
入口域名 <code>{html.escape(os.environ.get('PUBLIC_HOST','orgflow-sandbox.tail0b7621.ts.net'))}</code></p>
</div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            self._send(200, render_index()); return
        if path == "/api/health":
            self._send(200, json.dumps(health_list(), ensure_ascii=False), "application/json; charset=utf-8"); return
        if path == "/healthz":
            self._send(200, "ok", "text/plain"); return
        # 反代
        for prefix, backend in PROXY_ROUTES:
            if path == prefix.rstrip("/") or path.startswith(prefix):
                rest = path[len(prefix.rstrip("/")):]
                target = backend.rstrip("/") + "/" + rest.lstrip("/")
                # 保留 query
                if urllib.parse.urlparse(self.path).query:
                    target += "?" + urllib.parse.urlparse(self.path).query
                try:
                    req = urllib.request.Request(target, method="GET")
                    with urllib.request.urlopen(req, timeout=8) as r:
                        data = r.read()
                        ctype = r.headers.get("Content-Type", "text/html; charset=utf-8")
                        self._send(r.status, data, ctype)
                except urllib.error.HTTPError as e:
                    self._send(e.code, f"upstream {e.code}", "text/plain; charset=utf-8")
                except Exception as e:
                    self._send(502, f"502 bad gateway: {html.escape(str(e))}", "text/plain; charset=utf-8")
                return
        self._send(404, "404 not found", "text/plain; charset=utf-8")

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("GW_PORT", "18080"))
    host = os.environ.get("GW_HOST", "127.0.0.1")
    print(f"[gateway] 监听 {host}:{port}；服务 {len(SERVICES)} 个")
    ThreadingHTTPServer((host, port), Handler).serve_forever()
