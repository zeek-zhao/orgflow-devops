#!/usr/bin/env python3
"""文档自检：相对链接必须指向真实存在的路径。

为什么需要（2026-11-01）：文档改名或移动后，链接会**静默烂掉** —— markdown 渲染器
不会报错，读者点进去才发现 404。这类问题在「交接」场景里代价最高，因为接手人
分不清是文档错了还是自己找错了地方。

刻意不检查的两件事：
- **内容是否过期**：做不到可靠，硬做会变成要人手工维护的假检查，比没有更糟。
- **外部 URL**：网络抖动会让 CI 假红，而假红会训练人忽略红灯。

只查一件事：`[text](path)` 里的相对 path 在磁盘上存在。
绝对 URL、纯锚点、仓库根绝对路径一律跳过。
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 只认标准 markdown 行内链接；不认 reference-style（本仓库没用）。
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

# 这些前缀表示「不是本仓库内的相对路径」，跳过。
SKIP_PREFIXES = ("http://", "https://", "mailto:", "tel:", "#", "/", "data:")


def markdown_files():
    """仓库里所有需要保活的文档：根 README + docs 全量。"""
    yield ROOT / "README.md"
    yield from sorted((ROOT / "docs").rglob("*.md"))


def relative_targets(path):
    text = path.read_text(encoding="utf-8")
    for match in LINK.finditer(text):
        target = match.group(1)
        if target.startswith(SKIP_PREFIXES):
            continue
        yield target


class DocLinkTests(unittest.TestCase):
    def test_every_relative_link_resolves(self):
        broken = []
        for md in markdown_files():
            for target in relative_targets(md):
                # 去掉锚点与查询串：`foo.md#bar` 只需要 foo.md 存在。
                # 锚点本身查不了（GitHub 的锚点生成规则和本地不同），
                # 所以这里不假装能验它。
                clean = target.split("#", 1)[0].split("?", 1)[0]
                if not clean:
                    continue
                resolved = (md.parent / clean).resolve()
                if not resolved.exists():
                    broken.append(f"{md.relative_to(ROOT)} → {target}")
        self.assertEqual(
            broken,
            [],
            "相对链接指向不存在的路径（改名后忘了改链接？）：\n  " + "\n  ".join(broken),
        )

    def test_docs_index_covers_every_top_level_doc(self):
        """README 的文档索引必须覆盖 docs/ 下所有顶层 md。

        防的是「新写了文档但没人知道它存在」—— 这次补 M0-验收记录 和 待办
        两份文档时就是靠人工记得加索引，漏了不会有任何提示。
        """
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        missing = []
        for doc in sorted((ROOT / "docs").glob("*.md")):
            if doc.name not in readme:
                missing.append(doc.name)
        self.assertEqual(
            missing,
            [],
            "这些 docs/ 顶层文档没有出现在 README 的索引里：\n  " + "\n  ".join(missing),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
