"""用内部 CA 为每个站点子域签发叶子证书（SAN 由子域+网关域生成）。

放 scripts/lib/ 而不是 services/router/：渲染链（scripts/10-render-config.sh）
和路由注册 API（services/router/render.py）都要用它，services/router 是独立
镜像上下文、看不到仓根的 scripts/lib —— 所以由调用方把仓根 scripts/ 加进
sys.path 后 `import lib.site_certs`。

为什么要签发叶子证书而不是让 Caddy 自己签：
  - Caddy 的站点级 `tls cert key` 只接受**显式证书文件**，不会拿 CA 私钥现签；
    而 `local_certs` 自签的内部 CA 无法指定有效期、`down -v` 删卷就换根证书
    （每台客户端都得重装），M0 要求 CA 入库 + 有效期到 2036 → 只能自己签叶子。
  - 私钥与叶子证书放 secrets/ca/（不进 git）：CA 私钥只在本机，叶子证书按需现签。
    只有根证书 config/ca/orgflow-ca.crt 入库，客户端只需信任这一张。

用法:
  python3 scripts/lib/site_certs.py                # 按 routes.yaml 补齐缺失的证书
  python3 scripts/lib/site_certs.py --check        # 只检查，不写文件
  python3 scripts/lib/site_certs.py --days 3650    # 改有效期（默认 3650）
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def routes(root: Path):
    """返回 [(subdomain, domain)]，与 render.py / routes.yaml 是同一份真源。

    直接用 render.py 的解析器（它只认项目约定的极简 schema、零第三方依赖），
    不在这里另写一套 YAML 读取 —— 两套解析器迟早对不上。
    """
    sys.path.insert(0, str(root / "services" / "router"))
    import render  # noqa: E402

    text = (root / "config" / "routes.yaml").read_text(encoding="utf-8")
    settings, route_list = render.parse_routes_text(text)
    domain = os.environ.get("GATEWAY_DOMAIN") or settings.get("gateway_domain") or render.DEFAULT_DOMAIN
    return [(r["subdomain"], domain) for r in route_list]


def issue(ca_crt, ca_key, crt, key, sub, domain, days):
    days = str(days)
    with tempfile.TemporaryDirectory() as tmp:
        ext = Path(tmp) / "ext.cnf"
        san = f"DNS:{sub}.{domain}"
        ext.write_text(
            "basicConstraints=CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            f"subjectAltName={san}\n",
            encoding="utf-8",
        )
        csr = Path(tmp) / "leaf.csr"
        subprocess.run(
            ["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(key), "-out", str(csr),
             "-subj", f"/CN={sub}.{domain}"],
            check=True, capture_output=True,
        )
        subprocess.run(
            ["openssl", "x509", "-req", "-in", str(csr),
             "-CA", str(ca_crt), "-CAkey", str(ca_key), "-CAcreateserial",
             "-out", str(crt), "-days", days, "-sha256", "-extfile", str(ext)],
            check=True, capture_output=True,
        )
    os.chmod(key, 0o600)
    os.chmod(crt, 0o644)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--days", type=int, default=3650)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    root = ROOT
    ca_crt = root / "config" / "ca" / "orgflow-ca.crt"
    ca_key = Path(os.environ.get("CA_KEY") or (root / "secrets" / "ca" / "orgflow-ca.key"))
    if not ca_crt.exists() or not ca_key.exists():
        print(f"缺 {ca_crt} 或 {ca_key}：先跑 bash scripts/20-gen-ca.sh", file=sys.stderr)
        return 1

    out_dir = ca_key.parent / "sites"
    missing = []
    for sub, domain in routes(root):
        crt = out_dir / f"{sub}.{domain}.crt"
        key = out_dir / f"{sub}.{domain}.key"
        if args.force or not (crt.exists() and key.exists()):
            missing.append((sub, domain, crt, key))
    if args.check:
        for sub, domain, crt, _ in missing:
            print(f"缺：{crt}")
        print("证书齐全" if not missing else f"缺 {len(missing)} 张")
        return 0 if not missing else 1

    out_dir.mkdir(parents=True, exist_ok=True)
    for sub, domain, crt, key in missing:
        issue(ca_crt, ca_key, crt, key, sub, domain, args.days)
        print(f"签发：{crt}")
    print(f"完成：{len(missing)} 张新签，其余复用" if missing else "完成：无需签发")
    return 0


if __name__ == "__main__":
    sys.exit(main())
