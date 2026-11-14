#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BDD 三方对账门禁：tests/features/*.feature ↔ tests/bats/*.bats ↔ docs/requirements。

规则（#139 grill 决策 D）：
1. 每个 bats @test 必须有同名 Scenario（按文件配对），反之亦然；
2. 每个 Scenario 必须带 ≥1 个 @REQ-M0-xx 标签，且该 REQ 在 docs/requirements 里真实存在；
3. Scenario 名全局唯一。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FEAT_DIR = ROOT / "tests/features"
BATS_DIR = ROOT / "tests/bats"
REQ_DIR = ROOT / "docs/requirements"

TEST_RE = re.compile(r'^@test\s+"([^"]+)"', re.M)
SCEN_RE = re.compile(r"^\s{2}Scenario:\s*(.+)$", re.M)
TAG_RE = re.compile(r"^\s*(@[\w:.-]+\s*)$", re.M)
REQ_TAG_RE = re.compile(r"@(REQ-M0-[A-Z0-9-]+)")


def parse_features():
    out = {}
    for f in sorted(FEAT_DIR.glob("*.feature")):
        text = f.read_text(encoding="utf-8")
        # collect tags preceding each Scenario line
        scen = []
        for m in SCEN_RE.finditer(text):
            head = text[:m.start()]
            tags = []
            # 标签块紧贴 Scenario 行，取其上方几行收集 REQ 标签
            block = head.rstrip("\n").split("\n")[-6:]
            for line in block:
                for tm in REQ_TAG_RE.finditer(line):
                    tags.append(tm.group(1))
            scen.append((m.group(1).strip(), tags))
        out[f.stem] = scen
    return out


def parse_bats():
    out = {}
    for f in sorted(BATS_DIR.glob("*.bats")):
        out[f.stem] = TEST_RE.findall(f.read_text(encoding="utf-8"))
    return out


def req_ids():
    ids = set()
    for f in REQ_DIR.glob("*.md"):
        ids |= set(re.findall(r"REQ-M0-[A-Z0-9-]+", f.read_text(encoding="utf-8")))
    return ids


def main():
    errors = []
    feats = parse_features()
    bats = parse_bats()
    known = req_ids()

    if sorted(feats) != sorted(bats):
        errors.append(f"feature/bats 文件集合不一致：{set(feats) ^ set(bats)}")

    all_names = []
    for stem in sorted(bats):
        if stem not in feats:
            continue
        bnames = bats[stem]
        fnames = [n for n, _ in feats[stem]]
        if sorted(bnames) != sorted(fnames):
            only_b = [n for n in bnames if n not in fnames]
            only_f = [n for n in fnames if n not in bnames]
            errors.append(f"{stem}: 缺 Scenario 的用例 {only_b}；缺用例的 Scenario {only_f}")
        for name, tags in feats[stem]:
            all_names.append(name)
            if not tags:
                errors.append(f"{stem} :: {name[:50]} 没有任何 @REQ-M0-xx 标签")
            for t in tags:
                if t not in known:
                    errors.append(f"{stem} :: {name[:50]} 标签 {t} 在 docs/requirements 中不存在")

    dups = {n for n in all_names if all_names.count(n) > 1}
    if dups:
        errors.append(f"Scenario 名重复：{sorted(dups)}")

    if errors:
        print(f"✗ BDD 对账未通过（{len(errors)} 项）：")
        for e in errors:
            print("  -", e)
        sys.exit(1)
    print(f"✓ BDD 对账通过：{len(all_names)} 个 Scenario 与 bats 用例一一对应，REQ 标签全部有效")


if __name__ == "__main__":
    main()
