#!/usr/bin/env python3
"""门禁：workflow 里引用的第三方 Action 必须按 40 位 commit SHA 钉死。

为什么必须钉死：`@v4` 是可变引用，仓库所有者可以把 tag 挪到任意 commit。
Action 在自己的 job 里拿到仓库 token 和工作区，等于「谁控制 tag 谁就能改我们的流水线」。
SHA 不可变，所以这是唯一能保证「重跑同一个 commit 得到同一份代码」的写法。

同时要求同一行有 `# vN` 注释 —— 只留 SHA 的话，半年后没人知道这是哪个版本、
该不该升级；有注释才能判断「要不要跟」。

不检查的两种形式：
  - `uses: ./path`            本地 action，随仓库一起被审
  - `uses: docker://image:tag` 走镜像，由 digest 钉死（另有 check-image-source.sh 管）

用法：python3 scripts/check-actions-pinned.py [仓库根]
退出码：0 全部合规；1 有违规（逐行打印 文件:行号）
"""
from __future__ import annotations

import pathlib
import re
import sys

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
USES_RE = re.compile(r"^\s*-?\s*uses:\s*(\S+)\s*(?:#\s*(\S+))?\s*$")


def workflow_files(root: pathlib.Path) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for base in (".github/workflows", "public/.github/workflows"):
        d = root / base
        if d.is_dir():
            files += sorted(p for p in d.glob("*.yml"))
            files += sorted(p for p in d.glob("*.yaml"))
    return files


def check(root: pathlib.Path) -> list[str]:
    bad: list[str] = []
    for path in workflow_files(root):
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            m = USES_RE.match(line)
            if not m:
                continue
            target, comment = m.group(1), m.group(2)
            if target.startswith("./") or target.startswith("docker://"):
                continue
            where = f"{path.relative_to(root).as_posix()}:{lineno}"
            if "@" not in target:
                bad.append(f"{where}  缺少 @<sha>：{target}")
                continue
            name, _, ref = target.rpartition("@")
            if not SHA_RE.match(ref):
                bad.append(f"{where}  {name}@{ref} 未按 SHA 钉死（tag 可被移动）")
                continue
            if not comment or not re.match(r"^v\d", comment):
                bad.append(f"{where}  {name}@{ref[:8]}… 缺少 `# vN` 注释，无法判断版本")
    return bad


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    files = workflow_files(root)
    if not files:
        print(f"✗ 在 {root} 下没找到 workflow，检查本身失效了")
        return 1
    bad = check(root)
    if bad:
        print("✗ Action 引用不合规：")
        for b in bad:
            print(f"  {b}")
        print("\n修法：uses: owner/action@<40位sha> # vN")
        return 1
    print(f"✓ {len(files)} 个 workflow，Action 全部按 SHA 钉死且有版本注释")
    return 0


if __name__ == "__main__":
    sys.exit(main())
