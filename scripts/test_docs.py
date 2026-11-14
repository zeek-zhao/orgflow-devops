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


def compose_service_names():
    """从 docker-compose.yml 解析顶层 services: 下的服务名。

    只认两空格缩进的键（services 的直接子级）；不引第三方 yaml 库，
    缩进约定由仓库自己的 compose 文件保证（00_stack.bats 也依赖它）。
    """
    names = []
    in_services = False
    for raw in (ROOT / "docker-compose.yml").read_text(encoding="utf-8").splitlines():
        if raw.rstrip() == "services:":
            in_services = True
            continue
        if not in_services:
            continue
        if raw and not raw.startswith(" "):
            break  # services: 块结束
        if raw.startswith("  ") and not raw.startswith("   "):
            name = raw.strip().split(":", 1)[0].strip()
            if name and not name.startswith("#"):
                names.append(name)
    return names


class ServiceDocCoverageTests(unittest.TestCase):
    """M0 的每个服务必须有对应的 docs/services/<名字>.md。

    防的是「服务加了/改名了，文档没跟上」——服务文档是排障的第一入口
    （docs/services/ 统一六段），服务与文档一一对应这件事靠人记必烂。
    """

    # nexus 不在 compose 里（#46，由 job nexus-deploy 拉起），但它是 M0 服务。
    EXTRA_SERVICES = ("nexus",)
    # jjb 是 compose 里的工具容器（tools profile），不是对外服务，无文档。
    NON_SERVICES = ("jjb",)

    def test_every_service_has_a_doc(self):
        missing = []
        for name in compose_service_names() + list(self.EXTRA_SERVICES):
            if name in self.NON_SERVICES:
                continue
            if not (ROOT / "docs" / "services" / f"{name}.md").exists():
                missing.append(name)
        self.assertEqual(
            missing,
            [],
            "这些 M0 服务没有 docs/services/<名字>.md：\n  " + "\n  ".join(missing),
        )

    def test_every_service_doc_matches_a_service(self):
        """反向校验：docs/services/ 里的文档必须对应一个真实服务。

        服务改名/删除后留下的孤儿文档，读者会以为它还在跑。
        """
        known = set(compose_service_names()) | set(self.EXTRA_SERVICES)
        orphans = []
        for doc in sorted((ROOT / "docs" / "services").glob("*.md")):
            if doc.name == "README.md":  # 目录索引，已单独登记（DOC-E-007）
                continue
            if doc.stem not in known:
                orphans.append(doc.name)
        self.assertEqual(
            orphans,
            [],
            "这些 docs/services/ 文档不对应任何服务（服务改名/删掉了？）：\n  "
            + "\n  ".join(orphans),
        )


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
