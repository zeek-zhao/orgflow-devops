#!/usr/bin/env python3
"""发布物链接自洽检查（只对导出目录用）。

背景（P1-3）：内部仓里 docs/ 互相引用齐全，`scripts/test_docs.py` 全绿；
但导出时内部流程文档（会话交接/待办/验收记录/task-cards）被排除，
产品文档里指向它们的相对链接就全悬空了。旧门禁只查敏感词、不查链接，
于是「内部全绿、发布物全红」，而且没人发现。

用法：
    check_export_links.py <dir>            只报告，有死链即退出码 1
    check_export_links.py <dir> --strip    把悬空链接降级为纯文本，然后校验

降级而不是删句：读者仍能看到「这里提到过某份内部记录」，而发布物不出现 404。
内部仓原文不动，所以内部可追溯性不受影响。
"""
import os
import re
import sys

ROOT = ""

# [文字](目标) 与 ![替代文字](目标)；目标里允许带 "title"（会被忽略）
LINK = re.compile(r'(!?)\[([^\]]*)\]\(([^)\s]+?)(?:\s+"[^"]*")?\)')
SKIP_PREFIX = ("http://", "https://", "mailto:", "#", "tel:", "ftp://", "//")
SKIP_DIRS = {".git", "node_modules", "__pycache__"}


def md_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            if fn.endswith(".md"):
                yield os.path.join(dirpath, fn)


def resolve(md_path, target):
    """返回链接指向的本地路径；外部链接返回 None。"""
    t = target.split("#", 1)[0].split("?", 1)[0]
    if not t:
        return True  # 纯锚点
    t = t.replace("%20", " ")
    if t.startswith("/"):
        # GitHub 语义：以仓库根为根。导出目录就是发布物根。
        return os.path.normpath(os.path.join(ROOT, t.lstrip("/")))
    return os.path.normpath(os.path.join(os.path.dirname(md_path), t))


def scan(strip):
    dead = []
    for md in md_files(ROOT):
        try:
            text = open(md, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        if "](" not in text:
            continue

        changed = False
        out = []
        in_fence = False
        for line in text.splitlines(keepends=True):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                out.append(line)
                continue
            if in_fence:  # 代码块里的 [x](y) 是示例，不是链接
                out.append(line)
                continue

            def repl(m):
                nonlocal changed
                label, target = m.group(2), m.group(3)
                if target.startswith(SKIP_PREFIX):
                    return m.group(0)
                path = resolve(md, target)
                if path is True or os.path.exists(path):
                    return m.group(0)
                dead.append((md, target))
                if strip:
                    changed = True
                    return label
                return m.group(0)

            out.append(LINK.sub(repl, line))

        if strip and changed:
            with open(md, "w", encoding="utf-8") as fh:
                fh.write("".join(out))
    return dead


def main():
    global ROOT
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    strip = "--strip" in sys.argv[1:]
    if len(argv) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    ROOT = os.path.abspath(argv[0])
    if not os.path.isdir(ROOT):
        print(f"目录不存在: {ROOT}", file=sys.stderr)
        return 2

    dead = scan(strip)
    if strip:
        print(f"降级悬空链接 {len(dead)} 条（指向未导出的内部文档）")
        if dead:
            for md, target in dead[:10]:
                print(f"  {os.path.relpath(md, ROOT)} -> {target}")
            if len(dead) > 10:
                print(f"  ... 其余 {len(dead) - 10} 条同理")
        return 0

    if dead:
        print(f"✗ 发布物有 {len(dead)} 条悬空链接", file=sys.stderr)
        for md, target in dead[:20]:
            print(f"  {os.path.relpath(md, ROOT)} -> {target}", file=sys.stderr)
        return 1
    print("✓ 发布物链接自洽：0 条悬空链接")
    return 0


if __name__ == "__main__":
    sys.exit(main())
