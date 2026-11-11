#!/usr/bin/env python3
"""标签清单的离线校验（纳入 make test，不需要网络与 token）。

为什么离线也要查：标签是「仓库外部状态」，写错了 GitHub 不会报错 ——
Issue 模板里挂一个不存在的 label，创建出来的单子看起来正常，就是没有标签。
所以把「声明集合本身自洽」「模板只引用已声明的标签」这两件事做成门禁。

判据（任一不满足即非 0 退出）：
  1. 每个标签名匹配 `<前缀>/<小写短横线>`，前缀只能是 type/prio/area/state
  2. 颜色是 6 位十六进制且不带 #
  3. 描述非空（写「什么时候用它」，不写「标签」两个字）
  4. 名称唯一
  5. prio 集合恰好是 {P0,P1,P2}
  6. `.github/ISSUE_TEMPLATE/*.yml` 里 `labels: [...]` 引用的每个标签都必须在清单里

反证：把 task.yml 的 labels 改成 ["task"]（历史遗留名）-> 第 6 条红；
      把某个 color 改成 red -> 第 2 条红。
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LABELS_FILE = ROOT / ".github" / "labels.json"
TEMPLATES = ROOT / ".github" / "ISSUE_TEMPLATE"
NAME_RE = re.compile(r"^(type|prio|area|state)/[A-Za-z0-9][A-Za-z0-9-]*$")
COLOR_RE = re.compile(r"^[0-9a-f]{6}$")
TEMPLATE_LABELS_RE = re.compile(r"^labels:\s*\[(.*?)\]\s*$", re.MULTILINE)

fails: list[str] = []


def main() -> int:
    if not LABELS_FILE.exists():
        print(f"✗ 缺少 {LABELS_FILE}")
        return 1
    data = json.loads(LABELS_FILE.read_text(encoding="utf-8"))
    labels = data.get("labels", [])
    if not labels:
        fails.append("labels 为空")

    names: list[str] = []
    for item in labels:
        name = item.get("name", "")
        names.append(name)
        if not NAME_RE.match(name):
            fails.append(f"标签名不合规（要求 <type|prio|area|state>/xxx）: {name!r}")
        # 除 prio/P0..P2 外一律小写：大小写混用会让「标签存在但没匹配上」这种问题
        # 变成肉眼查不出来的错（GitHub 的 label 名区分大小写）。
        if not name.startswith("prio/") and name != name.lower():
            fails.append(f"{name}: 非 prio 前缀的标签必须全小写")
        if not COLOR_RE.match(item.get("color", "")):
            fails.append(f"{name}: 颜色必须是 6 位小写十六进制，且不带 #（当前 {item.get('color')!r}）")
        if len(item.get("description", "").strip()) < 4:
            fails.append(f"{name}: 描述太短，写清「什么时候用它」")
    duplicated = {n for n in names if names.count(n) > 1}
    if duplicated:
        fails.append(f"标签名重复: {sorted(duplicated)}")

    prios = {n.split("/", 1)[1] for n in names if n.startswith("prio/")}
    if prios != {"P0", "P1", "P2"}:
        fails.append(f"prio 集合应为 P0/P1/P2，实际 {sorted(prios)}")

    # Issue 模板里引用的标签必须已声明
    for template in sorted(TEMPLATES.glob("*.yml")):
        text = template.read_text(encoding="utf-8")
        for match in TEMPLATE_LABELS_RE.finditer(text):
            for raw in match.group(1).split(","):
                label = raw.strip().strip("\"'")
                if label and label not in names:
                    fails.append(f"{template.name}: 引用了未声明的标签 {label!r}")

    if fails:
        for item in fails:
            print(f"✗ {item}")
        return 1
    print(f"标签清单自检通过：{len(names)} 个标签，四类前缀齐备，模板引用全部已声明")
    return 0


if __name__ == "__main__":
    sys.exit(main())
