#!/usr/bin/env python3
"""路由注册服务：把 routes.yaml 渲染成 Caddyfile，并可热加载到 Caddy。

用法:
  render.py --routes config/routes.yaml --out out/Caddyfile
  render.py --routes config/routes.yaml --out out/Caddyfile --watch

设计：只支持本项目约定的极简 schema（listen + routes[path/upstream/strip_prefix]），
不依赖 PyYAML，保证零第三方依赖即可运行。
"""
import argparse
import os
import sys
import time
import urllib.request


def parse_routes(path):
    listen = ":8080"
    routes = []
    cur = None
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if s.startswith("listen:"):
                listen = s.split(":", 1)[1].strip().strip('"').strip("'")
                continue
            if s.startswith("- "):
                cur = {}
                routes.append(cur)
                s = s[2:].strip()
            if cur is None:
                continue
            if s.startswith("path:"):
                cur["path"] = s.split(":", 1)[1].strip().strip('"').strip("'")
            elif s.startswith("upstream:"):
                cur["upstream"] = s.split(":", 1)[1].strip().strip('"').strip("'")
            elif s.startswith("strip_prefix:"):
                v = s.split(":", 1)[1].strip().lower()
                cur["strip_prefix"] = v in ("true", "1", "yes")
    return listen, routes


def render(listen, routes):
    out = ["{", "\tadmin 0.0.0.0:2019", "}", "", f"{listen} {{"]
    for r in routes:
        p = r.get("path", "").rstrip("/") or "/"
        up = r.get("upstream", "")
        if not up:
            continue
        if r.get("strip_prefix"):
            out.append(f"\thandle_path {p}* {{")
        else:
            out.append(f"\thandle {p}* {{")
        out.append(f"\t\treverse_proxy {up}")
        out.append("\t}")
    out.append("}")
    return "\n".join(out) + "\n"


def write_if_changed(path, content):
    try:
        with open(path, "r", encoding="utf-8") as f:
            if f.read() == content:
                return False
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return True


def reload_caddy(caddyfile, admin_url):
    with open(caddyfile, "rb") as f:
        data = f.read()
    req = urllib.request.Request(
        admin_url.rstrip("/") + "/load",
        data=data,
        method="POST",
        headers={"Content-Type": "text/caddyfile"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status
    except Exception as e:  # noqa: BLE001
        print(f"[router] reload failed: {e}", file=sys.stderr)
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--routes", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--admin", default=os.environ.get("CADDY_ADMIN_URL", ""))
    args = ap.parse_args()

    def once():
        listen, routes = parse_routes(args.routes)
        content = render(listen, routes)
        changed = write_if_changed(args.out, content)
        if changed:
            print(f"[router] rendered {args.out} ({len(routes)} routes)")
            if args.admin:
                st = reload_caddy(args.out, args.admin)
                print(f"[router] caddy reload -> {st}")
        return changed

    if not args.watch:
        once()
        return

    last = None
    while True:
        try:
            m = os.path.getmtime(args.routes)
            if m != last:
                last = m
                once()
        except Exception as e:  # noqa: BLE001
            print(f"[router] watch error: {e}", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
