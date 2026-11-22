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
  - 全部站点用仓库自带的 orgflow 内部 CA（根证书 config/ca/），不向公网申请证书
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
from pathlib import Path

DEFAULT_DOMAIN = "org-devops.com"
# 认证网关站点的路由名。它的 subdomain 就是登录跳转的目标域名。
# 刻意不做成独立环境变量：AUTH_SUBDOMAIN 会与 Caddyfile 站点、dex 的 issuer、
# oauth2-proxy 的 redirect_url 形成四处独立声明，改一处不改另一处就静默错位。
AUTH_ROUTE_NAME = "auth"

# 内部 CA 的根证书来自 config/ca/（入库、有效期到 2036）；私钥与叶子证书在
# secrets/ca/（不进 git），一起挂在 caddy 容器的 /certs。
# 不再用 Caddy 自签的 local_certs：那样 `docker compose down -v` 删卷就换一把新根证书，
# 每台客户端都要重装一次。
#
# tls 是**站点级**指令，不能写进全局块 —— 所以每个站点块里都插一行。
#
# 用的是**每个子域一张叶子证书**（由 scripts/lib/site_certs.py 用同一把内部 CA
# 签出，SAN 只含该子域），而不是把 CA 自己的证书当站点证书：
#   - 浏览器/curl 认 SAN，CA 证书没有 SAN 时 openssl s_client 报 "No extensions in
#     certificate"，客户端校验链也会因为「证书主体是 CA」而拒绝；
#   - 私钥与叶子证书在 secrets/ca/（不进 git）：CA 私钥只在本机，叶子证书按需现签。
#     只有根证书 config/ca/orgflow-ca.crt 入库。
def tls_line(sub, domain):
    name = f"{sub}.{domain}"
    return f"\ttls /certs/sites/{name}.crt /certs/sites/{name}.key"
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
                tls_line("docs", domain),
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
        out.append(tls_line(sub, domain))
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


def artifact_is_current(routes_path, out_path):
    """产物 Caddyfile 是否等于「当前配置」渲染出来的内容。

    /healthz 每次都现场算，不读缓存状态。原因（#117 真机复现）：
    `make clean` 删掉 out/ 再重建时，容器内 bind mount 仍指向被删除的旧
    inode（nlink=0），watch 因为 routes.yaml 的 mtime 没变而不会重渲染，
    health_state 里那份「上次成功」的状态就会永远显示绿 —— 而 Caddy 手里
    其实是旧配置。只有把「文件里到底是什么」和「配置要求什么」当场比一次，
    这种失效才藏不住。
    """
    try:
        settings, routes = parse_routes(routes_path)
        return content_matches(out_path, render(apply_env(settings), routes))
    except (OSError, ValueError, KeyError, TypeError):
        return False


def write_if_changed(path, content):
    if content_matches(path, content):
        return False
    directory = os.path.dirname(path) or "."
    # bind mount 悬空的典型特征：目录还在、但 nlink 已归零（宿主侧被删后重建）。
    # 这时 tempfile 会抛 ENOENT，watch 每轮打印一行却永远不恢复；把原因说清楚，
    # 让人一眼知道要重建容器，而不是误判成「网络抖动、等等就好」。
    if os.path.isdir(directory):
        try:
            if os.stat(directory).st_nlink == 0:
                raise RuntimeError(
                    f"输出目录 {directory} 的 bind mount 已失效（nlink=0）：宿主目录被"
                    "删除并重建过，容器仍持有旧 inode。需重建 router 与 caddy 容器；"
                    "不要用 rm -rf out 清理，见 Makefile clean"
                )
        except FileNotFoundError:
            pass
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


# CLI（main）解析出 --routes/--out 后登记在这里；注册 API 的写入路径复用它。
# 用 dict 而不是单值：单测会在同一进程里起多个临时目录，单值会互相踩。
_OUT_PATHS: dict = {}


def _out_path_for(routes_path):
    """与 CLI 默认口径一致：Caddyfile 写在 routes.yaml 的同级目录。

    render.py --watch 的 out 路径由 --out 指定；注册 API 走的是同一份约定
    （容器里 /app/config/routes.yaml ↔ /app/out/Caddyfile 不同目录，所以
    还要认 ORGFLOW_OUT_DIR）。优先用环境变量，其次用同级目录。
    """
    registered = _OUT_PATHS.get(str(routes_path))
    if registered:
        return Path(registered)
    out_dir = os.environ.get("ORGFLOW_OUT_DIR")
    if out_dir:
        return Path(out_dir) / "Caddyfile"
    return Path(routes_path).parent / "Caddyfile"


def _ensure_site_certs(settings, routes):
    """给新加的子域补签叶子证书（缺一张，Caddy 热加载就会整份拒绝）。

    渲染链（scripts/10-render-config.sh）只在启动时补一次；API 在运行期加路由，
    必须自己补 —— 否则新配置引用的 /certs/sites/<子域>.crt 不存在，
    Caddy 返回 400 且**新配置完全不生效**（不是只缺那一条）。
    签发实现只有一份：scripts/lib/site_certs.py。router 镜像把仓根 scripts/lib
    挂在 /repo/scripts/lib（见 services/router/compose.yml），这里按需探测。
    """
    # 仓根定位：容器里 render.py 在 /app/render.py，`parents[2]` 会越界（IndexError），
    # 所以不能只靠文件位置猜 —— 先看显式配置，再看 compose 挂进来的两个挂载点。
    # 注意：缺证书**不是可以默默跳过的事**（缺一张 Caddy 就整份拒绝，且没有任何提示），
    # 所以除了「这个部署根本没配 CA 目录」，其余异常一律打印出来，别静默 return。
    candidates = [
        os.environ.get("ORGFLOW_ROOT"),
        "/repo",
        str(Path(__file__).resolve().parents[2]) if len(Path(__file__).resolve().parents) > 2 else None,
    ]
    root = next((c for c in candidates if c and (Path(c) / "config" / "ca").is_dir()), None)
    if not root:
        # 没配 CA 目录 = 这个部署不签证书（例如只跑渲染的 CI 单测），这是预期分支
        return
    lib = Path(root) / "scripts" / "lib"
    if not lib.is_dir():
        # 到这里说明「仓根找到了、但它不像仓库」——静默跳过会让 Caddyfile 引用一个
        # 不存在的证书，Caddy 整份拒配置且毫无提示，所以必须炸出来。
        raise RuntimeError(
            f"仓根 {root} 下没有 scripts/lib（缺 site_certs.py），无法为新子域签发证书"
        )
    if str(lib) not in sys.path:
        sys.path.insert(0, str(lib))
    try:
        import site_certs  # noqa: WPS433
    except ImportError as e:
        raise RuntimeError(f"无法从 {lib} 导入 site_certs：{e}") from e
    ca_crt = Path(root) / "config" / "ca" / "orgflow-ca.crt"
    # 私钥不进 git：默认 secrets/ca/，容器里由 compose 挂到同路径（见 router 片段）
    ca_key = Path(os.environ.get("CA_KEY") or (Path(root) / "secrets" / "ca" / "orgflow-ca.key"))
    if not (ca_crt.exists() and ca_key.exists()):
        raise RuntimeError(f"缺 CA 文件 {ca_crt} 或私钥 {ca_key}（先跑 bash scripts/20-gen-ca.sh）")
    domain = os.environ.get("GATEWAY_DOMAIN") or settings.get("gateway_domain") or DEFAULT_DOMAIN
    sites = ca_key.parent / "sites"
    for route in routes:
        sub = route["subdomain"]
        crt = sites / f"{sub}.{domain}.crt"
        key = sites / f"{sub}.{domain}.key"
        if not (crt.exists() and key.exists()):
            site_certs.issue(ca_crt, ca_key, crt, key, sub, domain, 3650)


def _write_routes_validated(path, new_text):
    """先按「改完的文本」完整走一遍 parse+render，全绿才落盘。

    这是 400 反证（文件 sha256 不变）的保证：非法输入在写之前就被拒绝。
    """
    settings, routes = parse_routes_text(new_text)
    env_settings = apply_env(settings)
    _ensure_site_certs(env_settings, routes)
    content = render(env_settings, routes)
    if write_if_changed(path, new_text):
        # 产物也要落盘：run 起来的时候，watch 循环靠 (mtime, size, inode) 判断
        # 「配置变了」——多了一个字节它就会自己重渲染。但路由顺序（先写 routes.yaml
        # 再热加载）要求新内容在热加载那一刻就已经在 out/Caddyfile 里，
        # 否则 Caddy 加载的还是旧文件，接口返回 201 而线上没生效。
        write_if_changed(_out_path_for(path), content)


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
            count = self.server.health_state.get("routes_count")
            # 光是「读到过配置」不够：Caddy 真正加载的是产物文件。
            # 响应体形状保持不变（ok / routes），只把 ok 的判据补严。
            ready = count is not None and artifact_is_current(
                self.server.routes_path, self.server.out_path)
            self._json(200 if ready else 503,
                       {"ok": ready, "routes": count or 0})
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
            except SystemExit as e:   # site_certs/openssl 失败时会 SystemExit
                self._json(502, {"error": f"证书签发失败：{e}"})
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
    # 注册 API 写 routes.yaml 时要顺手把产物写到同一处：--out 才是唯一真源，
    # 不能靠拼目录猜（容器里 /app/config 与 /app/out 是两个挂载点）。
    _OUT_PATHS[args.routes] = args.out

    watch_bootstrap = {"pending": True}

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
        # Caddy 还没起来时 reload 必然失败（router 被设计成先于 Caddy 就绪，
        # 见 docs/services/router.md 的启动顺序）—— 那是**预期**，不是错误：
        # 只要把 Caddyfile 写到 out/，Caddy 启动时就会读它。
        # 原先这里会让一次失败把 watch 循环打崩（进程退出 → 容器 unhealthy →
        # caddy 的 depends_on 失败 → 整栈起不来，2026-11-22 本地 DinD 实测）。
        # watch 模式下 Caddy 未就绪是常态（router 被设计成先于 Caddy 就绪，
        # 见 docs/services/router.md 的启动顺序），所以那一轮不算失败 —— 下一轮接着试。
        # 一次性模式下没有「下一轮」：热加载没成功 = 这份配置没进 Caddy，
        # 必须让调用方拿到非零退出码（否则 reload.sh 的 wrapper 永远看不见失败）。
        reloaded = False
        if args.admin and (changed or force_reload or watch_bootstrap):
            try:
                st = reload_caddy(content, args.admin)
                reloaded = True
                print(f"[router] caddy reload -> {st}", flush=True)
            except (RuntimeError, OSError) as e:
                if args.watch:
                    print(f"[router] 跳过热加载（Caddy 还没就绪，属预期，会重试）：{e}", flush=True)
                else:
                    print(f"[router] update failed: {e}; previous Caddyfile preserved",
                          file=sys.stderr)
                    # 产物仍然要写：Caddy 启动/重启读的就是这份文件，
                    # 「没进正在跑的 Caddy」不等于「不该发布这份配置」。
                    write_if_changed(args.out, content)
                    return False
        if write_if_changed(args.out, content):
            print(f"[router] rendered {args.out} ({len(routes)} routes)")
        # 重试判据：**Caddy 里装的配置**是否已经是最新。产物文件一致不等于
        # Caddy 一致（它可能重启后手里是旧配置，或者上一轮加载被拒）。
        # 只有在「不需要热加载」或「热加载刚成功」时才算收敛；否则每轮重试。
        # 收敛判据只取决于「本轮有没有热加载、热加载成功没有」。
        # 不能把 changed/force_reload 掺进来：那会让「配置没变」直接算收敛，
        # 于是 Caddy 起来之后永远等不到重试（2026-11-22 实测）。
        health_state["desired"] = not args.admin or reloaded
        health_state["routes_count"] = len(routes)
        watch_bootstrap["pending"] = False
        return True

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
            ok = once(force_reload=True)
        except (OSError, RuntimeError, ValueError) as e:
            print(f"[router] update failed: {e}; previous Caddyfile preserved", file=sys.stderr)
            return 1
        # 热加载没成功（Caddy 不可达/拒了配置）→ 非零退出。
        # 根 compose 里有同内容的 out/Caddyfile（Caddy 启动时会读它），所以「发布」本身
        # 不受影响；但一次性执行的调用方必须知道「这份配置没进正在跑的 Caddy」。
        return 0 if ok else 1

    last = None
    while True:
        try:
            stat = os.stat(args.routes)
            m = (stat.st_mtime_ns, stat.st_size, stat.st_ino)
            if m != last:
                once(force_reload=last is None)
                last = m
            elif not health_state.get("desired", True):
                # 配置没变，但**上一次热加载没成功**（Caddy 还没起来 / 拒了新配置）：
                # 不重试的话，这台机器会一直停在旧配置上，直到下次改 routes.yaml。
                # 判据由 once() 按「本轮热加载成功没有」重置，收敛后不再发无关请求；
                # interval 本身就在节流，不需要额外退避。
                once(force_reload=False)
        except (OSError, RuntimeError, ValueError) as e:
            print(f"[router] watch error: {e}; will retry", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
