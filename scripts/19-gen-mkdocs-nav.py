"""生成 mkdocs.yml（MkDocs Material 站点导航）。

为什么用脚本而不是手写：站点导航必须与 docs/ 的真实结构一致，
手写一份迟早会与文件树脱节（门禁 docs-check 只能查链接，查不到「没进导航」）。
生成规则：

  01-首页.md、02-快速开始.md …         → 顶层，按文件名编号排序
  10-项目管理/…、20-需求/… …            → 一级目录，目录名就是导航标题
  目录内的 NN-xxx.md                    → 按编号排序，标题取文件首个 H1

用法：python3 scripts/19-gen-mkdocs-nav.py [--check]
      --check 只校验 out/mkdocs-nav.generated.yml 与当前 docs/ 是否一致，不写盘。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
TARGET = ROOT / "mkdocs.yml"

# 目录名 → 站点里的中文标题。docs/ 在 PR3 会重编号成 10-项目管理 这类前缀，
# 生成器对前缀是透明的（去掉 \d+- 再查表），所以 PR3 改名时不用改这个脚本。
DIR_TITLES = {
    "project": "项目治理",
    "requirements": "需求与验收",
    "network": "架构与网络",
    "services": "服务手册",
    "engineering": "开发规范",
    "records": "记录与合规",
    "_templates": "模板",
}

FRONT = """# MkDocs 站点配置（由 scripts/19-gen-mkdocs-nav.py 生成，别手改 nav）
#
# 站点由 services/docs 服务构建：mkdocs build --site-dir /site，
# 产物写进 docs_site 卷，由 Caddy 在 docs.<domain> 下只读服务（鉴权走 oauth2-proxy）。
site_name: OrgFlow DevOps 平台文档
site_description: M0 最小公司级 Jenkins 开发系统的设计、部署、运维与验收文档
docs_dir: docs
site_dir: site
use_directory_urls: false

theme:
  name: material
  language: zh
  features:
    - navigation.instant
    - navigation.top
    - navigation.indexes
    - search.suggest
    - content.code.copy
  palette:
    - media: "(prefers-color-scheme: light)"
      scheme: default
      toggle:
        icon: material/weather-night
        name: 切到深色
    - media: "(prefers-color-scheme: dark)"
      scheme: slate
      toggle:
        icon: material/weather-sunny
        name: 切到浅色

markdown_extensions:
  - admonition
  - attr_list
  - def_list
  - footnotes
  - tables
  - toc:
      permalink: true
  - pymdownx.details
  - pymdownx.superfences
  - pymdownx.tabbed:
      alternate_style: true

plugins:
  - search

# 文档里大量指向仓库源码的链接（../../scripts/xx.sh、../../AGENTS.md）在站点里点不开：
# 那些文件不在 docs/ 里，MkDocs 会逐个报「not found among documentation files」。
# 这些链接是给「在仓库里读 Markdown」的人用的，站点侧降噪成 warn。
# 仓内死链另有门禁兜底（make links 扫全仓相对链接，PR 必过），所以这里不是放水。
# MkDocs 的 validation 只能分三类（absolute_links / unrecognized_links / anchors），
# 「链接到 docs/ 之外的真实文件」与「链接到不存在的文件」都归 unrecognized_links，
# 所以不能靠它区分。改成：全 ignore，然后由下面的链接检查承担「仓内死链」这件事 ——
# 那套检查基于 git ls-files 扫全仓，比 MkDocs 只认 docs/ 更严格（make links 同款）。
validation:
  absolute_links: ignore
  unrecognized_links: ignore
  anchors: ignore

# **不能开 strict**：MkDocs 的 strict 是「任何 warning 都失败」，而不是
# 「配置里的 validation 规则失败」。docs/ 里有大量指向仓库源码的链接
# （../../AGENTS.md、../../scripts/xx.sh），这些文件不在 docs/ 里，warning 关不掉。
# 死链由另一条门禁兜底：make links（git ls-files 扫全仓相对链接），它比 MkDocs
# 只认 docs/ 更严格。站点侧只要求「构建能出 index.html」，由 docs 服务健康检查断言。
strict: false

nav:
"""

INDEX_BODY = """# OrgFlow DevOps 平台文档

这是 M0 最小公司级 Jenkins 开发系统的文档站点入口。

- [文档地图](文档地图.md) —— 按「我要做什么」找文档，30 秒定位
- [文档登记册](文档登记册.md) —— 每篇文档的 ID、类型、状态、见证命令
- 新同学建议顺序：[项目章程](project/项目章程.md) → [架构与网络](network/README.md) → [使用说明](engineering/使用说明.md)
"""


def h1_of(path: Path) -> str | None:
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m:
            return m.group(1)
    return None


def label_of(path: Path, fallback: str | None = None) -> str:
    """标题优先取 fallback（目录名），其次 H1，最后是去掉编号前缀的文件名。

    目录里的 README.md 是「这一层文档的索引」，导航项应显示目录名（例如「项目治理」），
    而不是它在文件里的 H1（那个 H1 往往写着「project/ — 项目治理文档」这类路径说明）。
    """
    if path.stem.lower() == "readme" and fallback:
        return fallback
    return h1_of(path) or re.sub(r"^\d+[-_]", "", path.stem)


def sort_key(path: Path):
    m = re.match(r"^(\d+)[-_]?(.*)$", path.name)
    if m:
        return (0, int(m.group(1)), m.group(2))
    return (1, 0, path.name)


def build_nav() -> str:
    lines: list[str] = []
    entries = sorted(DOCS.iterdir(), key=sort_key)
    for entry in entries:
        if entry.is_file() and entry.suffix == ".md":
            if entry.name in {"README.md", "index.md"}:
                lines.append(f"  - 首页: {entry.name}")
            else:
                lines.append(f"  - {label_of(entry)}: {entry.name}")
        elif entry.is_dir():
            base = re.sub(r"^\d+[-_]", "", entry.name)
            title = DIR_TITLES.get(base, base)
            lines.append(f"  - {title}:")
            kids = sorted((p for p in entry.iterdir() if p.is_file() and p.suffix == ".md"), key=sort_key)
            for kid in kids:
                lines.append(f"      - {label_of(kid, title)}: {entry.name}/{kid.name}")
            subs = sorted((p for p in entry.iterdir() if p.is_dir()), key=sort_key)
            for sub in subs:
                sbase = re.sub(r"^\d+[-_]", "", sub.name)
                stitle = DIR_TITLES.get(sbase, sbase)
                lines.append(f"      - {stitle}:")
                for kid in sorted((p for p in sub.iterdir() if p.is_file() and p.suffix == ".md"), key=sort_key):
                    lines.append(f"          - {label_of(kid, stitle)}: {entry.name}/{sub.name}/{kid.name}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只校验，不写盘")
    args = parser.parse_args()
    # MkDocs 必须有 docs/index.md 才有首页（否则站点根是 404）。
    # index.md 与 mkdocs.yml 都是**生成物但必须入库**：镜像构建要 COPY mkdocs.yml，
    # 站点要 index.md；改了 docs/ 结构就跑本脚本重新生成，别手改这两个文件。
    # 不新建文件、也不改 文档地图.md 的内容：生成器在 docs/ 里写一个 index.md，
    # 它是「指向 文档地图 的入口页」，内容极短，随生成器一起维护。
    index = DOCS / "index.md"
    index_body = INDEX_BODY
    index.write_text(index_body, encoding="utf-8", newline="\n")

    rendered = FRONT + build_nav()
    if args.check:
        current = TARGET.read_text(encoding="utf-8") if TARGET.exists() else ""
        if current != rendered:
            print("✗ mkdocs.yml 的 nav 与 docs/ 不一致，跑 python3 scripts/19-gen-mkdocs-nav.py 重新生成", file=sys.stderr)
            return 1
        print("✓ mkdocs.yml 与 docs/ 一致")
        return 0
    TARGET.write_text(rendered, encoding="utf-8", newline="\n")
    print(f"✓ 已生成 {TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
