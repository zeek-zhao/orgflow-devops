#!/usr/bin/env python3
"""把 `.github/labels.json` 推到 GitHub（幂等）。

为什么要脚本：标签属于「仓库外部的状态」，改了模板却不改标签，新 Issue 会挂上一个
不存在的 label 名（GitHub 会静默忽略），看起来配好了其实没生效。

口径：
  - 只新增/更新，**默认不删**。删标签会把已关闭 Issue 上的历史标记一起抹掉，
    那不是收敛，是销毁证据。要用 `--prune` 显式删，且只删本文件声明的前缀之外的遗留。
  - 权限不足（403/404）时明确失败，不静默跳过 —— 私仓时代这条吃过亏。

用法：
  GITHUB_TOKEN=... python3 scripts/sync-labels.py            # 应用
  GITHUB_TOKEN=... python3 scripts/sync-labels.py --dry-run  # 只报告差异
  GITHUB_TOKEN=... python3 scripts/sync-labels.py --prune    # 额外删除四类前缀之外的遗留标签
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
LABELS_FILE = ROOT / ".github" / "labels.json"
API = "https://api.github.com"
REPO = os.environ.get("GITHUB_REPOSITORY", "zeek-zhao/orgflow-devops")
PREFIXES = ("type/", "prio/", "area/", "state/")


def request(method: str, path: str, token: str, payload: dict | None = None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{API}{path}", data=data, method=method,
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "orgflow-sync-labels",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode() or "null")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()[:300]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--prune", action="store_true")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("✗ 需要 GITHUB_TOKEN（repo 权限）", file=sys.stderr)
        return 2

    desired = json.loads(LABELS_FILE.read_text(encoding="utf-8"))["labels"]
    status, existing = request("GET", f"/repos/{REPO}/labels?per_page=100", token)
    if status != 200:
        print(f"✗ 读取标签失败 HTTP {status}: {existing}", file=sys.stderr)
        return 1
    current = {item["name"]: item for item in existing}

    created = updated = 0
    for label in desired:
        name = label["name"]
        body = {"new_name": name, "color": label["color"], "description": label["description"]}
        if name not in current:
            if args.dry_run:
                print(f"  + 新建 {name}")
            else:
                code, result = request("POST", f"/repos/{REPO}/labels", token,
                                       {"name": name, "color": label["color"],
                                        "description": label["description"]})
                if code != 201:
                    print(f"✗ 新建 {name} 失败 HTTP {code}: {result}", file=sys.stderr)
                    return 1
            created += 1
        else:
            old = current[name]
            if old.get("color", "").lower() == label["color"].lower() \
                    and old.get("description", "") == label["description"]:
                continue
            if args.dry_run:
                print(f"  ~ 更新 {name}")
            else:
                code, result = request("PATCH", f"/repos/{REPO}/labels/{name}", token, body)
                if code != 200:
                    print(f"✗ 更新 {name} 失败 HTTP {code}: {result}", file=sys.stderr)
                    return 1
            updated += 1

    legacy = sorted(n for n in current if not n.startswith(PREFIXES))
    if legacy:
        print(f"  遗留标签 {len(legacy)} 个（不在四类前缀里，保留为历史记录）："
              f"{' '.join(legacy)}")
        if args.prune:
            for name in legacy:
                if args.dry_run:
                    print(f"  - 删除 {name}")
                    continue
                code, result = request("DELETE", f"/repos/{REPO}/labels/{name}", token)
                if code not in (204, 404):
                    print(f"✗ 删除 {name} 失败 HTTP {code}: {result}", file=sys.stderr)
                    return 1
                print(f"  - 已删除 {name}")

    verb = "将" if args.dry_run else "已"
    print(f"✓ 标签同步完成：{verb}新建 {created} 个、{verb}更新 {updated} 个（共 {len(desired)} 个声明）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
