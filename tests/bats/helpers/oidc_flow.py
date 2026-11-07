#!/usr/bin/env python3
"""#86 权限用例的 OIDC 登录流程器：以指定账号走完 docs 站点的网关链路。

用法: oidc_flow.py <host> <https-port> <user> <password>
输出: 最后一跳的 HTTP 状态码与最终 URL,行为: 若会话建立则再 GET 首页一次。

链路: docs(401/302) → docs/oauth2/start → Dex LDAP 登录 → approval → 回 docs。
不校验 TLS(测试栈内部 CA,由 20_tls 单独验证链路)。
"""
import html
import re
import ssl
import sys
import socket
import urllib.parse
import urllib.request

host, port, user, password = sys.argv[1:5]
_domain_suffix = "." + host.split(".", 1)[1]

_orig_getaddrinfo = socket.getaddrinfo
def _patched_getaddrinfo(h, *a, **k):
    # http.client 在某些路径会把 host:port 整串传进来,判定前剥掉端口
    base = h.rsplit(":", 1)[0] if isinstance(h, str) and h.count(":") == 1 else h
    if isinstance(base, str) and base.endswith(_domain_suffix):
        return _orig_getaddrinfo("127.0.0.1", *a, **k)
    return _orig_getaddrinfo(h, *a, **k)
socket.getaddrinfo = _patched_getaddrinfo
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(
    NoRedirect, urllib.request.HTTPCookieProcessor(),
    urllib.request.HTTPSHandler(context=ctx))


def fetch(url, data=None, headers=None):
    for _ in range(10):
        req = urllib.request.Request(url, data=data, method="POST" if data else "GET",
                                     headers=headers or {})
        try:
            with opener.open(req, timeout=15) as r:
                return r.status, r.geturl(), r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location")
            if e.code in (301, 302, 303, 307) and loc:
                url = fix(loc if loc.startswith("http") else
                          urllib.parse.urljoin(url, html.unescape(loc)))
                data = None  # 303/302 后转 GET
                continue
            return e.code, url, e.read().decode("utf-8", "replace")
    raise RuntimeError("redirect loop")


def fix(url):
    """内层栈把 443 映射到 <port>:浏览器侧 URL 不带端口,请求时补上。
    已带端口的 URL(netloc 含冒号)原样返回,避免 host:443:443。"""
    parts = urllib.parse.urlsplit(url)
    if ":" in parts.netloc:
        return url
    return urllib.parse.urlunsplit(
        (parts.scheme, f"{parts.netloc}:{port}", parts.path, parts.query, parts.fragment))


def form_fields(text, base_url):
    m = re.search(r'<form[^>]*action="([^"]+)"', text)
    action = urljoin(base_url, html.unescape(m.group(1))) if m else base_url
    fields = {}
    for block in re.findall(r"<form[^>]*>.*?</form>", text, re.S) or [text]:
        for k, v in re.findall(r'<input[^>]*type="hidden"[^>]*name="([^"]+)"[^>]*value="([^"]*)"', block):
            fields[html.unescape(k)] = html.unescape(v)
    return action, fields


def login_flow(entry, user, password):
    url = fix(entry)
    for hop in range(20):
        print(f"hop{hop}: {url[:120]}", file=sys.stderr)
        status, url, body = fetch(url)
        if "/dex/auth/ldap/login" in url:
            action, fields = form_fields(body, url)
            fields["login"], fields["password"] = user, password
            status, url, body = fetch(action, data=urllib.parse.urlencode(fields).encode())
            if "/dex/approval" in url:
                block = re.search(r"<form[^>]*>.*?</form>", body, re.S).group(0)
                fields = {html.unescape(k): html.unescape(v) for k, v in
                          re.findall(r'<input[^>]*type="hidden"[^>]*name="([^"]+)"[^>]*value="([^"]*)"', block)}
                btn = re.search(r'<button[^>]*name="([^"]+)"[^>]*value="([^"]*)"', block)
                if btn:
                    fields[html.unescape(btn.group(1))] = html.unescape(btn.group(2))
                status, url, body = fetch(url, data=urllib.parse.urlencode(fields).encode())
            continue
        if "/oauth2/start" in url or "/oauth2/sign_in" in url:
            status, url, body = fetch(url)
            continue
        return status, url, body
    return status, url, body


try:
    status, url, body = login_flow(f"https://{host}:{port}/", user, password)
    print(status)
    print(url)
    print(body[:200].replace("\n", " "))
except Exception as exc:
    print("FLOW-ERROR")
    print(repr(exc)[:400])
    import traceback
    traceback.print_exc()
    sys.exit(3)
