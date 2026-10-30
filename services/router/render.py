#!/usr/bin/env python3
"""路由注册服务：把 routes.yaml 渲染成 Caddyfile，并可热加载到 Caddy。

用法:
  render.py --routes config/routes.yaml --out out/Caddyfile
  render.py --routes config/routes.yaml --out out/Caddyfile --watch

设计：只支持本项目约定的极简 schema（listen + routes[path/upstream/strip_prefix]），
不依赖 PyYAML，保证零第三方依赖即可运行。
"""
import argparse
import math
import os
import sys
import tempfile
import time
import urllib.error
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


def content_matches(path, content):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read() == content
    except FileNotFoundError:
        return False


def write_if_changed(path, content):
    if content_matches(path, content):
        return False
    directory = os.path.dirname(path) or "."
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--routes", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--admin", default=os.environ.get("CADDY_ADMIN_URL", ""))
    args = ap.parse_args()
    if not math.isfinite(args.interval) or args.interval <= 0:
        ap.error("--interval must be a finite positive number")

    def once(force_reload=False):
        listen, routes = parse_routes(args.routes)
        content = render(listen, routes)
        changed = not content_matches(args.out, content)
        # Bootstrap only in watch mode: Caddy needs a file before it can start.
        if args.watch and not os.path.exists(args.out):
            write_if_changed(args.out, content)
            print(f"[router] bootstrapped {args.out}; waiting for Caddy", flush=True)
        if args.admin and (changed or force_reload):
            st = reload_caddy(content, args.admin)
            print(f"[router] caddy reload -> {st}", flush=True)
        if write_if_changed(args.out, content):
            print(f"[router] rendered {args.out} ({len(routes)} routes)")

    if not args.watch:
        try:
            once(force_reload=True)
        except (OSError, RuntimeError, ValueError) as e:
            print(f"[router] update failed: {e}; previous Caddyfile preserved", file=sys.stderr)
            return 1
        return 0

    last = None
    while True:
        try:
            stat = os.stat(args.routes)
            m = (stat.st_mtime_ns, stat.st_size, stat.st_ino)
            if m != last:
                once(force_reload=last is None)
                last = m
        except (OSError, RuntimeError, ValueError) as e:
            print(f"[router] watch error: {e}; will retry", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
