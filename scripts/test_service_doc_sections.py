#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""服务文档四段覆盖自检（纳入 make test，见 #95 批次 1）。

背景：scripts/test_docs.py 只校验「服务 ↔ 文档一一对应」「相对链接」「README 索引」，
不检查文档内容。11 份 docs/services/*.md 统一追加「使用指南/注意事项/设置/备份」
四段后，需要一条静态断言防止有人删段而不被发现（任务卡的「反证」要求）。

本文件是**独立补充**，刻意不放宽 scripts/test_docs.py 的任何断言。
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVICES = ROOT / "docs" / "services"

REQUIRED = ("使用指南", "注意事项", "设置", "备份")
HEADING = re.compile(r"^##\s+(.+?)\s*$")


def section_titles(text):
    return [
        HEADING.match(line).group(1).strip()
        for line in text.splitlines()
        if HEADING.match(line)
    ]


def service_docs():
    return sorted(SERVICES.glob("*.md"))


class ServiceDocSectionTests(unittest.TestCase):
    def test_every_service_doc_has_four_sections(self):
        """每份服务文档都必须含四段，缺一即红（验收反证靠这条）。"""
        missing = []
        for doc in service_docs():
            titles = section_titles(doc.read_text(encoding="utf-8"))
            lack = [s for s in REQUIRED if s not in titles]
            if lack:
                missing.append("%s 缺：%s" % (doc.name, "、".join(lack)))
        self.assertEqual(
            missing,
            [],
            "以下服务文档缺必需四段（使用指南/注意事项/设置/备份）：\n  "
            + "\n  ".join(missing),
        )

    def test_every_service_doc_keeps_six_sections(self):
        """保留既有六段结构：^## 段数下限 6（追加四段后实际为 10+）。"""
        thin = []
        for doc in service_docs():
            count = sum(
                1
                for line in doc.read_text(encoding="utf-8").splitlines()
                if line.startswith("## ")
            )
            if count < 6:
                thin.append("%s 只有 %d 段" % (doc.name, count))
        self.assertEqual(
            thin,
            [],
            "以下服务文档 ^## 段数不足 6（既有六段结构不能推翻）：\n  "
            + "\n  ".join(thin),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
