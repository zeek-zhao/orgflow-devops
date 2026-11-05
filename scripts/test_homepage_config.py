#!/usr/bin/env python3
"""Homepage 配置静态核对（#94 / REQ-M0-C1）。

为什么是静态核对：本轮禁止停止/重启任何容器，「停掉 of-nexus 看首页变 down」
这条运行时反证做不了。改为在配置层盯住每张服务卡的探测字段——删掉任一探测字段
自检必须红，恢复后复绿。运行时状态翻转列为未验证项。

不用 PyYAML：CI 的 make test 跑在裸 ubuntu-24.04 python3 上，仓库现有
scripts/test_docs.py 也刻意不引第三方 yaml 库。这里按仓库自己的缩进约定解析。
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HP = ROOT / "config" / "homepage"

CARD = re.compile(r"^ {4}- (.+?):\s*$")
FIELD = re.compile(r"^ {8}([A-Za-z][A-Za-z0-9_]*):\s*(.*)$")
WIDGET = re.compile(r"^- ([A-Za-z][A-Za-z0-9_]*):\s*$")
WOPT = re.compile(r"^ {4}([A-Za-z][A-Za-z0-9_]*):\s*(.*)$")
GROUP = re.compile(r"^- (.+?):\s*$")
BOOKMARK = re.compile(r"^ {4}- (.+?):\s*$")
BITEM = re.compile(r"^ {8}- (.*)$")
BFIELD = re.compile(r"^ {8,}([A-Za-z][A-Za-z0-9_]*):\s*(.*)$")


def service_cards(text):
    """services.yaml → [{name, fields}]，只认 4 空格服务名 / 8 空格字段。"""
    cards = []
    for raw in text.splitlines():
        m = CARD.match(raw)
        if m:
            cards.append({"name": m.group(1).strip(), "fields": {}})
            continue
        if cards:
            f = FIELD.match(raw)
            if f:
                cards[-1]["fields"][f.group(1)] = f.group(2).strip()
    return cards


def widget_list(text):
    """widgets.yaml → [{type, options}]。"""
    out = []
    for raw in text.splitlines():
        m = WIDGET.match(raw)
        if m:
            out.append({"type": m.group(1), "options": {}})
            continue
        if out:
            f = WOPT.match(raw)
            if f:
                out[-1]["options"][f.group(1)] = f.group(2).strip()
    return out


def bookmark_groups(text):
    """bookmarks.yaml → [{name, items:[{name, fields, is_list_value}]}]。"""
    groups = []
    cur = None
    for raw in text.splitlines():
        m = GROUP.match(raw)
        if m:
            cur = {"name": m.group(1).strip(), "items": []}
            groups.append(cur)
            continue
        if cur is None:
            continue
        b = BOOKMARK.match(raw)
        if b:
            cur["items"].append({"name": b.group(1).strip(), "fields": {}, "is_list_value": False})
            continue
        if not cur["items"]:
            continue
        item = cur["items"][-1]
        it = BITEM.match(raw)
        if it:
            item["is_list_value"] = True
            kv = re.match(r"^([A-Za-z][A-Za-z0-9_]*):\s*(.*)$", it.group(1))
            if kv:
                item["fields"][kv.group(1)] = kv.group(2).strip()
            continue
        f = BFIELD.match(raw)
        if f:
            item["fields"][f.group(1)] = f.group(2).strip()
    return groups


class ServiceCardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (HP / "services.yaml").read_text(encoding="utf-8")
        cls.cards = service_cards(cls.text)

    def test_at_least_six_service_cards(self):
        self.assertGreaterEqual(len(self.cards), 6, "首页至少要有 6 张服务卡")

    def test_every_service_has_probe_fields(self):
        missing = []
        for c in self.cards:
            absent = [k for k in ("siteMonitor", "ping") if not c["fields"].get(k)]
            if absent:
                missing.append(c["name"] + " 缺 " + ",".join(absent))
        self.assertEqual(missing, [], "服务卡缺探测/状态字段（删掉就红）：\n  " + "\n  ".join(missing))

    def test_every_service_explains_usage(self):
        bad = [c["name"] for c in self.cards if "怎么用" not in c["fields"].get("description", "")]
        self.assertEqual(bad, [], "服务卡没写清怎么用：\n  " + "\n  ".join(bad))

    def test_every_service_links_its_doc(self):
        bad = [c["name"] for c in self.cards if "docs/services/" not in c["fields"].get("description", "")]
        self.assertEqual(bad, [], "服务卡没指向自己的文档：\n  " + "\n  ".join(bad))

    def test_docs_path_count_matches_cards(self):
        n = sum(1 for line in self.text.splitlines() if "docs/" in line)
        self.assertGreaterEqual(n, len(self.cards), "grep -c docs/ 应 >= 服务卡数")


class WidgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (HP / "widgets.yaml").read_text(encoding="utf-8")
        cls.widgets = widget_list(cls.text)

    def test_datetime_widget_present(self):
        self.assertIn("datetime", [w["type"] for w in self.widgets], "缺时间组件")

    def test_weather_widget_is_customapi(self):
        types = [w["type"] for w in self.widgets]
        self.assertIn("customapi", types, "天气用 customapi + Open-Meteo")
        for banned in ("openweathermap", "weather", "openmeteo", "sitemonitor"):
            self.assertNotIn(banned, types, "widgets.yaml 不应出现 " + banned)

    def test_weather_url_has_no_apikey(self):
        apis = [w for w in self.widgets if w["type"] == "customapi"]
        self.assertEqual(len(apis), 1)
        url = apis[0]["options"].get("url", "").strip().strip('"').strip("'")
        self.assertIn("api.open-meteo.com/v1/forecast", url)
        self.assertIn("current=temperature_2m", url)
        for banned in ("apikey", "api_key", "appid", "token=", "key=", "&key"):
            self.assertNotIn(banned, url.lower(), "天气 URL 含凭据参数 " + banned)

    def test_no_credential_fields(self):
        bad = []
        for raw in self.text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            for kw in ("apikey:", "apiKey:", "key:", "token:", "username:", "password:", "api_key:"):
                if line.startswith(kw):
                    bad.append(line)
        self.assertEqual(bad, [], "widgets.yaml 出现需要凭据的字段：\n  " + "\n  ".join(bad))


class BookmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.groups = bookmark_groups((HP / "bookmarks.yaml").read_text(encoding="utf-8"))

    def test_bookmark_values_are_lists(self):
        bad = []
        for g in self.groups:
            for it in g["items"]:
                if not it["is_list_value"] or not it["fields"].get("href"):
                    bad.append(g["name"] + " / " + it["name"])
        self.assertEqual(bad, [], "书签的值必须是列表且带 href（写成映射前端 new URL(e.href) 会炸）：\n  " + "\n  ".join(bad))

    def test_every_service_doc_has_bookmark(self):
        docs = sorted(p.name for p in (ROOT / "docs" / "services").glob("*.md"))
        hrefs = " ".join(it["fields"].get("href", "") for g in self.groups for it in g["items"])
        missing = [d for d in docs if d not in hrefs]
        self.assertEqual(missing, [], "这些服务文档没有可点开的直链：\n  " + "\n  ".join(missing))

    def test_local_doc_bookmarks_explain_usage(self):
        groups = [g for g in self.groups if g["name"] == "本地文档"]
        self.assertEqual(len(groups), 1, "缺「本地文档」书签分组")
        for it in groups[0]["items"]:
            self.assertIn("·", it["name"], "书签没写清怎么用：" + it["name"])
            self.assertTrue(it["fields"].get("href", "").startswith("http"), "书签 href 不可点：" + it["name"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
