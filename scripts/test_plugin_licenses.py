#!/usr/bin/env python3
"""门禁：插件许可证清单必须覆盖 plugins.txt 的每一项，且不许留「待核实」。

为什么需要这条：许可证清单只在一种情况下会错 —— 加了插件、忘了补清单。而加插件的人
不会主动去看合规文档，所以只能靠检查反向发现。判据不设「大概覆盖」，是逐名对齐。

判据：
  1. plugins.txt 的每个插件，在 plugins-licenses.md 的表格里都有一行
  2. 清单里没有 UNKNOWN / 待核实 / TBD / 以 XX 为主 这类含糊值
  3. 每行都写了一个 SPDX 形态的许可证标识和出处
  4. 清单行数与插件数相等（防止清单里塞了已删除的插件）
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGINS = ROOT / "services/jenkins/plugins.txt"
LICENSES = ROOT / "services/jenkins/plugins-licenses.md"

# SPDX 常见形态；不追求穷举，只要求「看起来是个许可证标识」而不是一句散文
SPDX_RE = re.compile(r"^(MIT|Apache-2\.0|GPL-[23]\.0(-only|-or-later)?|LGPL-[\d.]+|"
                     r"EPL-[12]\.0|BSD-[23]-Clause|MPL-2\.0|CDDL-1\.0|"
                     r"OpenLDAP|PSF-2\.0|Unlicense|ISC)$")
VAGUE = ("unknown", "待核实", "tbd", "todo", "以 ", "为主", "?")
# 必须带 re.M：不带的话 ^/$ 只匹配整串首尾，一行表格都读不到，
# 而报错信息会变成「检查本身失效」—— 那次是我自己踩的，记在这里免得再犯
ROW_RE = re.compile(r"^\|\s*(\d+)\s*\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*\|\s*$", re.M)


def main() -> int:
    fails: list[str] = []

    names = [ln.strip() for ln in PLUGINS.read_text(encoding="utf-8").splitlines()
             if ln.strip() and not ln.startswith("#")]
    if not names:
        print("✗ plugins.txt 读不出插件清单，检查本身失效了")
        return 1

    text = LICENSES.read_text(encoding="utf-8")
    rows = ROW_RE.findall(text)
    if not rows:
        print(f"✗ {LICENSES.name} 里没有解析到表格行，检查本身失效了")
        return 1

    declared = {}
    for num, plugin, lic, source in rows:
        lic = lic.strip()
        if any(v in lic.lower() for v in VAGUE):
            fails.append(f"第 {num} 行 {plugin}: 许可证写作「{lic}」，含糊值不接受")
            continue
        if not SPDX_RE.match(lic):
            fails.append(f"第 {num} 行 {plugin}: 「{lic}」不是可识别的 SPDX 标识")
        if not source.strip():
            fails.append(f"第 {num} 行 {plugin}: 缺少出处")
        declared[plugin] = lic

    missing = [n for n in names if n not in declared]
    for n in missing:
        fails.append(f"插件 {n} 在 plugins.txt 里，但许可证清单里没有")

    extra = [p for p in declared if p not in names]
    for p in extra:
        fails.append(f"清单里的 {p} 不在 plugins.txt 里（可能已删除插件，清单要跟着删）")

    if fails:
        print("✗ 插件许可证清单不合规：")
        for f in fails:
            print(f"  {f}")
        return 1

    lics = sorted(set(declared.values()))
    print(f"✓ {len(declared)} 个插件全部有许可证与出处（{', '.join(lics)}）")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1:
        ROOT = pathlib.Path(sys.argv[1]).resolve()
        PLUGINS = ROOT / "services/jenkins/plugins.txt"
        LICENSES = ROOT / "services/jenkins/plugins-licenses.md"
    sys.exit(main())
