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
    python3 scripts/nexus-setup-repos.py                # 213 部署机（凭据读 .env）
    NEXUS_BASE_URL=http://172.31.0.21:8081 python3 scripts/nexus-setup-repos.py
    # 测试 harness（router 容器内，凭据走环境变量优先）：
    NEXUS_BASE_URL=http://nexus:8081 NEXUS_ADMIN_ID=... NEXUS_ADMIN_PASSWORD=... \
        python3 /tmp/nexus-setup-repos.py

凭据从环境变量或 .env 读（环境变量优先），不落日志。
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
ENV = ROOT / ".env"


def env(key: str) -> str:
    if not ENV.exists():
        return ""
    for line in ENV.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
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
    print("✗ NEXUS_ADMIN_PASSWORD 没有来源（环境变量与 .env 都没有）", file=sys.stderr)
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
