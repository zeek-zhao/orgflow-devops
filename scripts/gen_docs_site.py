#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 docs/**/*.md 编成同构 HTML 静态站点（纯标准库、离线、可复跑）。

产物：--out 下与 docs/ 相同的目录结构、扩展名 .html，外加 index.html。
    docs/services/jenkins.md  ->  <out>/services/jenkins.html
批次 2 的 docs 受保护路由（依赖 #86）可把 root 指到该目录；本脚本只产生产物，
不碰 config/routes.yaml / services/router/ / out/Caddyfile。

最小披露：EXCLUDE_FILES / EXCLUDE_DIRS 里的文档（含明文口令 / 内部派工 / 验收结论）
不编入公开站点，编入内容再做一次口令兜底脱敏（REDACT_LITERALS）。
指向未编入文档或站点外 .md 的链接降级为纯文本，避免死链。

    python3 scripts/gen_docs_site.py
    python3 scripts/gen_docs_site.py --docs docs --out out/docs-site
"""

from __future__ import annotations

import argparse
import html
import posixpath
import re
import sys
from pathlib import Path

# 不编入公开站点：按最小披露（含明文口令 / 内部派工 / 验收结论）
EXCLUDE_FILES = {
    "账号与登录.md",          # 含初始明文占位口令
    "身份命名规范.md",        # 含口令值决策描述
    "M0-增量需求总表.md",               # 含口令值与内部决策取证
    "M0-验收记录.md",         # 验收结论（不改也不外放）
    "会话交接.md",           # 内部现状 / 陷阱 / 凭据路径
    "AI会话清单.md",         # 内部开工 SOP
    "待办.md",               # 内部派工
    "提交规范.md",           # 内部流程
    "派单流程.md",           # 内部流程
}
EXCLUDE_DIRS = {"task-cards"}

# 兜底脱敏：已知演示初始口令一律不落地。
# 最小披露：字面量不在源码里出现，用 ASCII 码构造，避免仓库/日志留下明文口令。
REDACT_LITERALS = ("".join(chr(c) for c in (49, 50, 51, 52, 53, 54)),)
REDACT_PLACEHOLDER = "[按最小披露隐去]"

SKIP_PREFIXES = ("http://", "https://", "mailto:", "tel:", "#", "/", "data:")

HTML_HEAD = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · orgflow-devops 文档</title>
<style>
 body{{font-family:-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;
      line-height:1.7;max-width:960px;margin:0 auto;padding:24px;color:#24292f}}
 h1,h2,h3{{border-bottom:1px solid #d0d7de;padding-bottom:.3em;margin-top:1.6em}}
 h2{{margin-top:2em}}
 a{{color:#0969da;text-decoration:none}} a:hover{{text-decoration:underline}}
 code{{background:#f6f8fa;border-radius:6px;padding:.15em .4em;font-size:.92em}}
 pre{{background:#f6f8fa;border-radius:8px;padding:14px;overflow:auto}}
 pre code{{background:none;padding:0}}
 table{{border-collapse:collapse;width:100%;margin:1em 0}}
 th,td{{border:1px solid #d0d7de;padding:6px 12px;text-align:left;vertical-align:top}}
 th{{background:#f6f8fa}}
 blockquote{{margin:1em 0;padding:0 1em;color:#57606a;border-left:.25em solid #d0d7de}}
 nav{{background:#f6f8fa;border-radius:8px;padding:12px 18px;margin-bottom:24px}}
 .tag{{color:#57606a;font-size:.9em}}
</style></head><body>
<nav><a href="{home}index.html">文档首页</a> · <span class="tag">源：docs/*.md；由 <code>scripts/gen_docs_site.py</code> 生成，请勿手改</span></nav>
"""


def is_excluded(rel):
    parts = rel.replace("\\", "/").split("/")
    if parts[0] in EXCLUDE_DIRS:
        return True
    return parts[-1] in EXCLUDE_FILES


def slug(text):
    """与 GitHub 一致的中文锚点：去行内标记，小写，空白转 -，保留中文与字母数字。"""
    s = re.sub(r"`([^`]*)`", r"\1", text)
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = s.strip().lower()
    s = re.sub(r"[^\w\u4e00-\u9fff\- ]+", "", s)
    return s.replace(" ", "-")


INLINE = re.compile(r"`([^`]+)`|\[([^\]]*)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*")


def render_inline(text, rewrite_link):
    out = []
    pos = 0
    for m in INLINE.finditer(text):
        out.append(html.escape(text[pos:m.start()], quote=False))
        if m.group(1) is not None:                       # 行内代码
            out.append("<code>%s</code>" % html.escape(m.group(1), quote=False))
        elif m.group(2) is not None:                     # 链接
            label = html.escape(m.group(2), quote=False)
            href = rewrite_link(m.group(3))
            out.append(label if href is None else '<a href="%s">%s</a>' % (href, label))
        else:                                            # 粗体
            out.append("<strong>%s</strong>" % html.escape(m.group(4), quote=False))
        pos = m.end()
    out.append(html.escape(text[pos:], quote=False))
    return "".join(out)


def make_rewriter(current_rel):
    base = posixpath.dirname(current_rel)

    def rewrite(target):
        if target.startswith(SKIP_PREFIXES):
            return html.escape(target, quote=True)
        clean = target.split("#", 1)[0].split("?", 1)[0]
        suffix = target[len(clean):]
        if not clean.endswith(".md"):
            return html.escape(target, quote=True)
        norm = posixpath.normpath(posixpath.join(base, clean))
        if norm.startswith("..") or is_excluded(norm):
            return None                                  # 站点外 / 未编入 → 去链接留文字
        return html.escape(clean[:-3] + ".html" + suffix, quote=True)

    return rewrite


def render_markdown(md_text, current_rel):
    rewrite = make_rewriter(current_rel)
    lines = md_text.splitlines()
    out = []
    i, n = 0, len(lines)

    def is_table_sep(s):
        return bool(re.match(r"^\s*\|?[\s:\-\|]+\|?\s*$", s)) and "-" in s

    while i < n:
        line = lines[i]

        if line.lstrip().startswith("```"):
            buf = []
            i += 1
            while i < n and not lines[i].lstrip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            out.append("<pre><code>%s</code></pre>" % html.escape("\n".join(buf), quote=False))
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            title = m.group(2).strip()
            out.append('<h%d id="%s">%s</h%d>' % (level, slug(title), render_inline(title, rewrite), level))
            i += 1
            continue

        if "|" in line and i + 1 < n and is_table_sep(lines[i + 1]):
            header = [c.strip() for c in line.strip().strip("|").split("|")]
            i += 2
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            out.append("<table><thead><tr>" + "".join("<th>%s</th>" % render_inline(c, rewrite) for c in header) + "</tr></thead><tbody>")
            for row in rows:
                out.append("<tr>" + "".join("<td>%s</td>" % render_inline(c, rewrite) for c in row) + "</tr>")
            out.append("</tbody></table>")
            continue

        if line.lstrip().startswith(">"):
            buf = []
            while i < n and lines[i].lstrip().startswith(">"):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append("<blockquote>%s</blockquote>" % render_inline(" ".join(buf), rewrite))
            continue

        if re.match(r"^\s*[-*]\s+", line) or re.match(r"^\s*\d+[.)]\s+", line):
            ordered = bool(re.match(r"^\s*\d+[.)]\s+", line))
            tag = "ol" if ordered else "ul"
            items = []
            while i < n and (re.match(r"^\s*[-*]\s+", lines[i]) or re.match(r"^\s*\d+[.)]\s+", lines[i])):
                item = re.sub(r"^\s*(?:[-*]|\d+[.)])\s+", "", lines[i])
                items.append("<li>%s</li>" % render_inline(item, rewrite))
                i += 1
            out.append("<%s>%s</%s>" % (tag, "".join(items), tag))
            continue

        if re.match(r"^\s*(---|\*\*\*|___)\s*$", line):
            out.append("<hr>")
            i += 1
            continue

        if not line.strip():
            i += 1
            continue

        para = [line]
        i += 1
        while i < n and lines[i].strip() and not re.match(
            r"^(#{1,6})\s|^\s*```|^\s*[-*]\s|^\s*\d+[.)]\s|^\s*>|^\s*(---|\*\*\*|___)\s*$",
            lines[i],
        ):
            para.append(lines[i])
            i += 1
        out.append("<p>%s</p>" % render_inline(" ".join(para), rewrite))

    return "\n".join(out)


def build_index(pages, excluded_list):
    groups = {}
    for _, html_rel in pages:
        groups.setdefault(posixpath.dirname(html_rel) or ".", []).append(html_rel)
    parts = ["<h1>orgflow-devops 文档站</h1>",
             "<p>由 <code>scripts/gen_docs_site.py</code> 离线生成，可重复运行；"
             "每份服务文档的「使用指南 / 注意事项 / 设置 / 备份」四段可用锚点直达。</p>"]
    for group in sorted(groups):
        parts.append("<h2>%s</h2><ul>" % html.escape(group))
        for html_rel in sorted(groups[group]):
            parts.append('<li><a href="%s">%s</a></li>' % (
                html.escape(html_rel, quote=True), html.escape(posixpath.basename(html_rel)[:-5])))
        parts.append("</ul>")
    parts.append("<h2>未编入（最小披露）</h2>")
    parts.append("<p>以下文档含明文口令 / 内部派工 / 验收结论，按最小披露不编入公开站点；"
                 "编入内容另做一次口令兜底脱敏。</p><ul>")
    for rel in sorted(excluded_list):
        parts.append("<li><code>%s</code></li>" % html.escape(rel))
    parts.append("</ul>")
    return HTML_HEAD.format(title="索引", home="") + "\n".join(parts) + "\n</body></html>\n"


def main():
    ap = argparse.ArgumentParser(description="把 docs/*.md 编成离线 HTML 静态站点")
    ap.add_argument("--docs", default="docs", help="markdown 源目录（默认 docs）")
    ap.add_argument("--out", default="out/docs-site", help="HTML 输出目录（默认 out/docs-site）")
    args = ap.parse_args()

    docs = Path(args.docs)
    out = Path(args.out)
    if not docs.is_dir():
        sys.exit("docs 目录不存在：%s" % docs)

    out.mkdir(parents=True, exist_ok=True)
    for old in out.rglob("*.html"):          # 可复跑：先清旧产物，不动其它文件
        old.unlink()

    pages, excluded_list, redacted = [], [], 0
    for md in sorted(docs.rglob("*.md")):
        rel = md.relative_to(docs).as_posix()
        if is_excluded(rel):
            excluded_list.append(rel)
            continue
        text = md.read_text(encoding="utf-8")
        title = rel
        for ln in text.splitlines():
            if ln.startswith("# "):
                title = ln[2:].strip()
                break
        body = render_markdown(text, rel)
        for literal in REDACT_LITERALS:
            redacted += body.count(literal)
            body = body.replace(literal, REDACT_PLACEHOLDER)

        html_rel = rel[:-3] + ".html"
        target = out / html_rel
        target.parent.mkdir(parents=True, exist_ok=True)
        home = "../" * (len(Path(rel).parts) - 1)
        target.write_text(
            HTML_HEAD.format(title=html.escape(title), home=home) + body + "\n</body></html>\n",
            encoding="utf-8",
        )
        pages.append((rel, html_rel))

    (out / "index.html").write_text(build_index(pages, excluded_list), encoding="utf-8")

    key = out / "services" / "jenkins.html"
    print("生成 %d 页 + index.html；排除 %d 份；脱敏 %d 处" % (len(pages), len(excluded_list), redacted))
    print("输出目录：%s" % out.resolve())
    if not key.exists():
        sys.exit("缺少关键产物：%s" % key)
    print("关键产物：%s OK" % key.as_posix())


if __name__ == "__main__":
    main()
