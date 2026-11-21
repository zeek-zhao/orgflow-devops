#!/usr/bin/env python3
"""#117：幂等初始化 Nexus —— CE EULA 接受、匿名开启、docker/pypi 三件套（hosted/proxy/group）。

背景与判据见 docs/services/nexus.md §「仓库三件套」「重部署复测与匿名策略」。

为什么逐条建、逐条打印：Nexus 的 REST schema 各版本有差异，错一个字段回来的是
400 + 一段 schema 报错；一次建六个再排查，成本远高于逐条跑。

全新 Nexus（卷重建 / CI 测试栈）有两道门挡着「能登录但用不了」，2026-11-14 CI 实测：

1. CE EULA：不接受时所有写路径（POST /components、建仓库）都 403
   "You must accept the End User License Agreement ..."。接受方式：
   GET /service/rest/v1/system/eula 拿 disclaimer 原样回传
   {"accepted": true, "disclaimer": ...}（3.92.2 实测 204）。
2. 匿名默认关闭：anonymous.enabled=false，验收里「未认证可拉」的判据会变 401。
   开启走 PUT /service/rest/v1/security/anonymous。

两步都幂等：已接受 / 已开启就跳过，213 上重跑同样安全。

Nexus 的 8081 没有映射到宿主端口，宿主侧要走容器 IP —— 而 IP 在容器重建后会变，
所以默认每次 `docker inspect` 现取，不写死。也可以用 NEXUS_BASE_URL 显式指定。

用法：
    python3 scripts/72-nexus-setup-repos.py                # 213 部署机（凭据读 .env）
    NEXUS_BASE_URL=http://172.31.0.21:8081 python3 scripts/72-nexus-setup-repos.py
    # 测试 harness（router 容器内，凭据走环境变量优先）：
    NEXUS_BASE_URL=http://nexus:8081 NEXUS_ADMIN_ID=... NEXUS_ADMIN_PASSWORD=... \
        python3 /tmp/nexus-setup-repos.py

凭据从环境变量或 out/runtime.env（旧部署为 .env）读（环境变量优先），不落日志。
"""
import base64
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
# 凭据来源顺序（与 scripts/70-nexus-deploy.sh 一致）：
#   out/runtime.env（真机与 harness 的唯一真源，make deploy 生成）→ .env（旧部署遗留）。
# 只读 .env 会让全新部署树直接报「NEXUS_ADMIN_PASSWORD 没有来源」（2026-11-22 实测）。
ENV_CANDIDATES = (ROOT / "out" / "runtime.env", ROOT / ".env")


def env(key: str) -> str:
    for candidate in ENV_CANDIDATES:
        if not candidate.exists():
            continue
        for line in candidate.read_text(encoding="utf-8").splitlines():
            if line.startswith(f"{key}="):
                value = line.split("=", 1)[1].strip()
                # 渲染器给含逗号/空格的值加了双引号，读回来要剥掉
                if len(value) >= 2 and value[0] == value[-1] == '"':
                    value = value[1:-1]
                return value
    return ""


def nexus_base_url() -> str:
    override = os.environ.get("NEXUS_BASE_URL", "").rstrip("/")
    if override:
        return override
    out = subprocess.run(
        ["docker", "inspect", "-f",
         "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", "of-nexus"],
        capture_output=True, text=True,
    ).stdout.strip()
    for tok in out.split():
        if tok.count(".") == 3:
            return f"http://{tok}:8081"
    print("✗ 取不到 of-nexus 的 IP；请用 NEXUS_BASE_URL 显式指定", file=sys.stderr)
    sys.exit(1)


USER = os.environ.get("NEXUS_ADMIN_ID") or env("NEXUS_ADMIN_ID") or "admin"
PW = os.environ.get("NEXUS_ADMIN_PASSWORD") or env("NEXUS_ADMIN_PASSWORD")
if not PW:
    print("✗ NEXUS_ADMIN_PASSWORD 没有来源（环境变量 / out/runtime.env / .env 都没有）", file=sys.stderr)
    sys.exit(1)

BASE = nexus_base_url()
AUTH = "Basic " + base64.b64encode(f"{USER}:{PW}".encode()).decode()


def call(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"Authorization": AUTH, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:500]
    except urllib.error.URLError as e:
        return -1, str(e)


def accept_eula() -> int:
    """CE EULA：GET 拿 disclaimer 原样回传 {"accepted": true}。返回失败数（0/1）。"""
    st, d = call("GET", "/service/rest/v1/system/eula")
    if st != 200 or not isinstance(d, dict):
        print(f"  ✗ EULA 状态读取失败 HTTP {st}: {d}", file=sys.stderr)
        return 1
    if d.get("accepted"):
        print("  = CE EULA        已接受，跳过")
        return 0
    disclaimer = d.get("disclaimer", "")
    if not disclaimer:
        print("  ✗ EULA disclaimer 为空，无法原样回传", file=sys.stderr)
        return 1
    st, d2 = call("POST", "/service/rest/v1/system/eula",
                  {"accepted": True, "disclaimer": disclaimer})
    if st == 204:
        print("  ✓ CE EULA        接受成功（HTTP 204）")
        return 0
    print(f"  ✗ CE EULA        接受失败 HTTP {st}: {d2}", file=sys.stderr)
    return 1


def enable_anonymous() -> int:
    """匿名读：验收判据「未认证可拉」依赖它。幂等。返回失败数（0/1）。"""
    st, d = call("GET", "/service/rest/v1/security/anonymous")
    if st != 200 or not isinstance(d, dict):
        print(f"  ✗ 匿名状态读取失败 HTTP {st}: {d}", file=sys.stderr)
        return 1
    if d.get("enabled"):
        print("  = 匿名访问       已开启，跳过")
        return 0
    st, d2 = call("PUT", "/service/rest/v1/security/anonymous",
                  {"enabled": True, "userId": "anonymous",
                   "realmName": "NexusAuthorizingRealm"})
    if st in (200, 204):
        print("  ✓ 匿名访问       开启成功")
        return 0
    print(f"  ✗ 匿名访问       开启失败 HTTP {st}: {d2}", file=sys.stderr)
    return 1


def storage(write: bool) -> dict:
    s = {"blobStoreName": "default", "strictContentTypeValidation": True}
    if write:
        s["writePolicy"] = "allow"
    return s


HTTP_CLIENT = {
    "blocked": False,
    "autoBlock": True,
    "connection": {"retries": 2, "userAgent": "", "timeout": 60,
                   "enableCircularRedirects": False, "enableCookies": False},
}

# docker-hosted:8082 是唯一能 push 的 connector。
# docker-group:8083 只做 pull —— Nexus OSS 向 group push 会返回
#   "Deploying to groups is a PRO-licensed feature"（3.92.2 实测），
# 所以 config/routes.yaml 的 docker 子域指 8082，group 留作容器网络内聚合入口。
# 公网代理仓库（docker-proxy / pypi-proxy 之类）能不能建，取决于 **Nexus 容器自己
# 能不能解析公网域名**。CI / DinD 里 Nexus 与其余服务同在一个隔离的 docker 网络，
# 该网络的 DNS 上游是测试专用的 dnsmasq，公网解析在那里就断了 —— 这不是配置
# 写错，而是「测试环境天然没有公网出口」。
#
# 判据必须从 **Nexus 容器里**探，不能用宿主 Python 的 getaddrinfo：
# 2026-11-22 实测宿主机解析 pypi.org 正常、Nexus 容器 `nslookup` 超时 ——
# 在宿主上探会得出「有公网」的错误结论，于是 proxy 建仓失败反而看着像脚本 bug。
def _nexus_can_resolve() -> bool:
    if os.environ.get("NEXUS_REQUIRE_INTERNET") == "1":
        return True
    container = os.environ.get("NEXUS_CONTAINER", "of-nexus")
    try:
        p = subprocess.run(
            ["docker", "exec", container, "sh", "-c",
             "nslookup pypi.org >/dev/null 2>&1 || getent hosts pypi.org >/dev/null 2>&1"],
            capture_output=True, timeout=20)
        return p.returncode == 0
    except Exception:
        return True   # 探不了就按「有公网」处理，让真实错误暴露出来


OFFLINE = os.environ.get("NEXUS_ALLOW_OFFLINE_PROXY") != "1" and not _nexus_can_resolve()


SPECS = [
    ("docker/hosted", "docker-hosted", {
        "name": "docker-hosted", "online": True, "storage": storage(True),
        "docker": {"httpPort": 8082, "httpsPort": None,
                   "forceBasicAuth": True, "v1Enabled": False},
        "component": {"proprietaryComponents": True},
    }),
    ("docker/proxy", "docker-proxy", {
        "name": "docker-proxy", "online": True, "storage": storage(False),
        "proxy": {"remoteUrl": "https://registry-1.docker.io",
                  "contentMaxAge": 1440, "metadataMaxAge": 1440},
        "negativeCache": {"enabled": True, "timeToLive": 1440},
        "httpClient": HTTP_CLIENT,
        "docker": {"httpPort": None, "httpsPort": None,
                   "forceBasicAuth": True, "v1Enabled": False},
        "dockerProxy": {"indexType": "HUB", "cacheForeignLayers": False},
    }),
    ("docker/group", "docker-group", {
        "name": "docker-group", "online": True, "storage": storage(False),
        "group": {"memberNames": ["docker-hosted", "docker-proxy"]},
        "docker": {"httpPort": 8083, "httpsPort": None,
                   "forceBasicAuth": True, "v1Enabled": False},
    }),
    ("pypi/hosted", "pypi-hosted", {
        "name": "pypi-hosted", "online": True, "storage": storage(True),
        "component": {"proprietaryComponents": True},
    }),
    ("pypi/proxy", "pypi-proxy", {
        "name": "pypi-proxy", "online": True, "storage": storage(False),
        # 报「Proxy URL blocked: Failed to resolve host: pypi.org」时，先查
        # **容器自己的 DNS 能不能解析公网**：Nexus 容器如果只配了内网 dnsmasq
        # （`--dns 172.31.0.2`），而 dnsmasq 的上游又是它自己所在网络的
        # Docker 内嵌 DNS，公网域名在这里就断了（2026-11-22 harness 实测：
        # 宿主机能解析、Nexus 容器解析超时）。这不是 remoteUrl 写法问题。
        "proxy": {"remoteUrl": "https://pypi.org",
                  "contentMaxAge": 1440, "metadataMaxAge": 1440},
        "negativeCache": {"enabled": True, "timeToLive": 1440},
        "httpClient": HTTP_CLIENT,
    }),
    ("pypi/group", "pypi-group", {
        "name": "pypi-group", "online": True, "storage": storage(False),
        "group": {"memberNames": ["pypi-hosted", "pypi-proxy"]},
    }),
]


def create_repos() -> int:
    st, existing = call("GET", "/service/rest/v1/repositories")
    if not isinstance(existing, list):
        print(f"✗ 列仓库失败 HTTP {st}: {existing}", file=sys.stderr)
        return 1
    have = {r["name"] for r in existing}
    print(f"起始 {len(have)} 个仓库：{sorted(have)}\n")

    fail = 0
    for kind, name, payload in SPECS:
        if name in have:
            print(f"  = {name:<16} 已存在，跳过")
            continue
        if OFFLINE and ("proxy" in payload or "group" in payload):
            # 没有公网出口时，proxy 仓库必然建不成、group 又会因为缺成员一起红，
            # 于是「台账一片红」掩盖了真正的问题。这里显式跳过并说清原因。
            print(f"  - {name:<16} 跳过（无公网出口，proxy/group 需要能解析上游）")
            continue
        st, d = call("POST", f"/service/rest/v1/repositories/{kind}", payload)
        if st in (200, 201, 204):
            print(f"  ✓ {name:<16} 建成（HTTP {st}）")
        else:
            fail += 1
            print(f"  ✗ {name:<16} HTTP {st}")
            print(f"      {d if isinstance(d, str) else json.dumps(d, ensure_ascii=False)}")

    st, after = call("GET", "/service/rest/v1/repositories")
    names = sorted(r["name"] for r in after) if isinstance(after, list) else []
    print(f"\n最终 {len(names)} 个仓库：")
    for n in names:
        print(f"  - {n}")
    return fail


def main():
    fail = 0
    print(f"Nexus @ {BASE}（用户 {USER}）")
    print("\n== CE EULA ==")
    fail += accept_eula()
    print("\n== 匿名访问 ==")
    fail += enable_anonymous()
    print("\n== 仓库三件套 ==")
    fail += create_repos()
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
