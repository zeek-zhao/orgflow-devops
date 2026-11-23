#!/usr/bin/env python3
"""HomePage —— 静态面板服务器。

- 读 /etc/homepage/bookmarks.yaml 渲染卡片（≤5 张）
- 每次请求重新读配置 → 改 YAML 免重启生效
- 解析失败/字段缺失显式报错（500 + 原因），不静默丢项
"""
import html
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import yaml
except ImportError:
    yaml = None

CONF = os.environ.get("BOOKMARKS", "/etc/homepage/bookmarks.yaml")
MAX_CARDS = 5


def load_cards():
    if yaml is None:
        raise RuntimeError("PyYAML 未安装，无法解析卡片配置")
    with open(CONF, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    cards = data.get("cards")
    if not isinstance(cards, list):
        raise ValueError("bookmarks.yaml 的 cards 必须是列表（映射会静默丢项，已拒绝）")
    if len(cards) > MAX_CARDS:
        raise ValueError(f"卡片数 {len(cards)} > 上限 {MAX_CARDS}")
    for i, c in enumerate(cards):
        if not isinstance(c, dict) or not c.get("name") or not c.get("href"):
            raise ValueError(f"第 {i+1} 张卡片缺 name/href")
    return cards


def render(cards):
    items = "\n".join(
        f'<li><a href="{html.escape(c["href"])}">{html.escape(c["name"])}</a>'
        f'<span>{html.escape(str(c.get("desc", "")))}</span></li>'
        for c in cards
    )
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>HomePage</title>
<style>body{{font-family:sans-serif;margin:2rem;background:#fafafa}} li{{margin:.6rem 0}}
a{{font-size:1.2rem;color:#06c}} span{{color:#666;margin-left:.8rem}}</style></head>
<body><h1>HomePage</h1><ul>{items}</ul></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/index.html"):
            self.send_response(404); self.end_headers(); return
        try:
            body = render(load_cards()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            body = f"配置错误: {html.escape(str(e))}".encode()
            self.send_response(500)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 3000), Handler).serve_forever()
