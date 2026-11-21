#!/usr/bin/env python3
"""文档配置管理门禁（IEEE 828 轻量落地）。

查什么、为什么：

1. **登记册完整性** —— docs/ 下每篇文档都必须在 `docs/文档登记册.md` 里有配置项。
   防的是「文档写完了但没人知道它存在、也不知道谁负责」（IEEE 828 §配置标识）。
2. **路径双向一致** —— 登记册里的路径必须真实存在，磁盘上的文档必须在册。
   单向检查会漏掉「文档被删了但登记册还挂着」这种腐烂。
3. **DOC-ID 唯一且合规** —— 同一个编号不能指两份文档（828 §配置控制）。
4. **状态与见证匹配** —— `approved` 必须有评审日期；`superseded` 必须写明被谁替代。
   状态是自我声明，没有见证字段就等于没有状态。
5. **复审超期提醒** —— 不是错误（WARN）：文档不会因为到期就变错，但需要有人看一眼。
6. **期望值溯源（WARN）** —— `deploy.sh` 与 Windows 验收脚本里的每个状态码期望，
   必须标明它出自哪个 issue。见 `check_expected_values()` 的说明。

刻意不做：判内容是否过期、判外部 URL 是否可达（网络抖动会造成假红，
假红会训练人忽略红灯 —— 这条教训写在 scripts/test_docs.py 的模块注释里）。

用法:
    python3 scripts/check_docs_meta.py            # 检查，非零退出即有硬错误
    python3 scripts/check_docs_meta.py --emit     # 打印登记册骨架（未登记的文档）
    python3 scripts/check_docs_meta.py --list     # 打印全量清单
"""

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
REGISTER = DOCS / "文档登记册.md"

# 模板不是配置项（它们没有独立生命周期，随使用者派生而存在）
EXCLUDE_DIRS = {"_templates"}
EXCLUDE_FILES = {"文档登记册.md"}

LAYERS = {"入口", "规程", "参考", "记录"}
STATUSES = {"draft", "review", "approved", "superseded", "archived"}
# 任务卡（TC-）已从编号体系摘掉：卡就是 GitHub Issue，仓库里不再存卡文件。
# 留着一个没有使用者的编号格式，只会让下一个人以为「该建卡文件了」。
ID_PATTERN = re.compile(r"^(DOC-[EPRL]-\d{3}|ADR-\d{2,3})$")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# 期望值出处标记：`#86` / `# 86` / `#initial`。两种都收，不然格式之争会变成 WARN 噪音。
TRACE_RE = re.compile(r"#\s*(\d+|initial)\b")

COLUMNS = ["DOC-ID", "标题", "路径", "层级", "状态", "负责人", "评审日期", "复审(月)", "关联"]


def doc_files():
    out = []
    for path in sorted(DOCS.rglob("*.md")):
        rel = path.relative_to(ROOT).as_posix()
        if any(part in EXCLUDE_DIRS for part in path.relative_to(DOCS).parts):
            continue
        if path.name in EXCLUDE_FILES:
            continue
        out.append((path, rel))
    return out


def parse_register(text):
    """返回 [(行号, {列名: 值})]。只认以 | 开头且含 DOC-ID 形态的表行。

    空行只在「已经读过数据行」之后才关闭表 —— 表头与表体之间夹一个空行
    是合法 markdown（渲染结果不变），早期版本在这里重置表头，导致整张表
    被静默跳过、56 篇全报「未登记」。
    """
    rows = []
    header = None
    seen_data = False
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped.startswith("|"):
            if not stripped and seen_data:
                header = None
                seen_data = False
            elif stripped:
                header = None
                seen_data = False
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if header is None:
            if cells and cells[0] == "DOC-ID":
                header = cells
            continue
        if set("".join(cells)) <= set("-: "):  # 分隔行
            continue
        if len(cells) != len(header):
            rows.append((lineno, {"__malformed__": f"列数 {len(cells)} != 表头 {len(header)}"}))
            seen_data = True
            continue
        rows.append((lineno, dict(zip(header, cells))))
        seen_data = True
    return rows


def wait_for(rel, path):
    title = rel
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("#"):
            title = line.lstrip("#").strip()
            break
    return title


def emit(registered):
    tf = doc_files()
    pending = [(p, r) for p, r in tf if r not in registered]
    print(f"# 待登记 {len(pending)} 篇 / 全量 {len(tf)} 篇")
    print("| " + " | ".join(COLUMNS) + " |")
    print("|" + "|".join(["---"] * len(COLUMNS)) + "|")
    for path, rel in pending:
        title = wait_for(rel, path).replace("|", "/")
        print(f"| DOC-X-000 | {title} | {rel} | 参考 | draft | - | - | 12 | - |")


def check_expected_values():
    """期望值必须有出处（WARN，不阻断）。

    反面教材是真实发生过的两次：`deploy.sh` 写死 `jenkins / 302`，而 #86 之后 Jenkins
    自己回 403 —— 于是这个脚本在任何**正确**的环境上都必然失败；类似的还有根证书判据
    只查「存在任一 Caddy 根证书」，旧证书骗过检查、验收显示通过。

    共同根因不是「写错了」，而是期望值和架构变更没绑在一起：改架构的人不知道脚本里
    埋着期望值，写期望值的人不知道架构改了。

    这里只认已经落地的两种形态，**不试图通用地识别「任何数字」** —— 那会把超时、
    端口、行号全当成期望值，刷出一屏 WARN，然后没人再看（假红训练人忽略红灯）。

    为什么是 WARN 而不是 error：存量里还有没溯源的值（标 `#initial` 的那些），
    一次红一片的结果是被人整体关掉，而不是被修好。
    """
    warnings = []
    targets = [
        (ROOT / "scripts/deploy.sh", "sh"),
        (ROOT / "tools/win-acceptance/Test-OrgflowAcceptance.ps1", "ps1"),
    ]
    for path, kind in targets:
        if not path.exists():
            warnings.append(f"{path.name} 不存在，期望值溯源检查未执行（改名了？）")
            continue
        lines = path.read_text(encoding="utf-8").splitlines()

        if kind == "sh":
            for idx, line in enumerate(lines):
                if "for check in" not in line:
                    continue
                block = line
                probe = idx
                while "; do" not in block and probe + 1 < len(lines):
                    probe += 1
                    block += " " + lines[probe]
                for spec in re.findall(r'"([^"]*)"', block):
                    parts = spec.split()
                    if not parts or not TRACE_RE.search(parts[-1]):
                        warnings.append(
                            f"{path.name}:{idx + 1} 期望值「{spec}」缺少出处（行尾应写 #NN 或 #initial）")
        else:
            for idx, line in enumerate(lines, 1):
                if not re.search(r"'[\w.-]+'\s*=\s*@\([^)]*\)", line):
                    continue
                if not TRACE_RE.search(line):
                    warnings.append(
                        f"{path.name}:{idx} 期望值缺少出处：{line.strip()}")

    return warnings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true", help="打印未登记文档的表格骨架")
    ap.add_argument("--list", action="store_true", help="打印全量文档清单")
    args = ap.parse_args()

    files = doc_files()
    on_disk = {rel for _, rel in files}

    if args.list:
        for _, rel in files:
            print(rel)
        return 0

    if not REGISTER.exists():
        print(f"✗ 找不到登记册：{REGISTER.relative_to(ROOT)}", file=sys.stderr)
        return 2

    rows = parse_register(REGISTER.read_text(encoding="utf-8"))
    registered = {}
    errors = []
    warnings = []

    for lineno, row in rows:
        if "__malformed__" in row:
            errors.append(f"登记册第 {lineno} 行：{row['__malformed__']}")
            continue
        doc_id = row.get("DOC-ID", "")
        path = row.get("路径", "")
        if not doc_id or doc_id in ("-", "DOC-ID"):
            continue
        if path in registered:
            errors.append(f"重复登记：{path}（第 {registered[path][0]} 行与第 {lineno} 行）")
        registered[path] = (lineno, row)

    if args.emit:
        emit(set(registered))
        return 0

    # 1) 双向一致
    for rel in sorted(on_disk - set(registered)):
        errors.append(f"未登记：{rel}（在 docs/ 下但不在登记册里）")
    for path in sorted(set(registered) - on_disk):
        errors.append(f"登记册指向不存在的文件：{path}")

    # 2) 单行字段校验
    seen_ids = {}
    today = dt.date.today()
    for path, (lineno, row) in sorted(registered.items()):
        tag = f"{row.get('DOC-ID', '?')} ({path})"
        doc_id = row.get("DOC-ID", "")
        layer = row.get("层级", "")
        status = row.get("状态", "")

        if not ID_PATTERN.match(doc_id):
            errors.append(f"{tag}：DOC-ID 不合规（应形如 DOC-E-001 / ADR-13）")
        if doc_id in seen_ids:
            errors.append(f"DOC-ID 重复：{doc_id}（{seen_ids[doc_id]} 与 {path}）")
        seen_ids[doc_id] = path
        if layer not in LAYERS:
            errors.append(f"{tag}：层级 '{layer}' 非法（只能是 {'/'.join(sorted(LAYERS))}）")
        if status not in STATUSES:
            errors.append(f"{tag}：状态 '{status}' 非法（只能是 {'/'.join(sorted(STATUSES))}）")

        review = row.get("评审日期", "-")
        if status == "approved":
            if not DATE_PATTERN.match(review):
                errors.append(f"{tag}：状态 approved 但没有评审日期（YYYY-MM-DD）")
            elif dt.date.fromisoformat(review) > today:
                errors.append(f"{tag}：评审日期 {review} 在未来")
        if status == "superseded":
            note = (row.get("关联", "") + row.get("标题", ""))
            if "→" not in note and "->" not in note:
                errors.append(f"{tag}：状态 superseded 但没写被谁替代（关联列用 → 指向新文档）")

        # 3) 复审超期（WARN，不阻断）
        months = row.get("复审(月)", "")
        if status == "approved" and DATE_PATTERN.match(review) and months.isdigit() and int(months) > 0:
            due = dt.date.fromisoformat(review) + dt.timedelta(days=30 * int(months))
            if due < today:
                warnings.append(f"{tag}：评审已超期（{review} + {months} 月 = {due}）")

    warnings.extend(check_expected_values())

    for w in warnings:
        print(f"  [WARN] {w}")
    if errors:
        print(f"✗ 文档门禁未通过，{len(errors)} 处问题：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(f"✓ 文档门禁通过：{len(registered)} 篇登记项，ID 唯一、状态与见证匹配、路径双向一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
