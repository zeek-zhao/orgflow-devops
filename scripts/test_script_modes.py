#!/usr/bin/env python3
"""门禁：所有顶层可执行脚本必须有可执行位。

为什么：部署链、bats、harness 都以 `bash script` 或 `./script` 直接调用脚本，
一旦文件权限退回 0664（git mv / 编辑器重写 / 跨文件系统复制都可能发生），
真机与 CI 都会出现「No such file or directory」这种完全看不出是权限问题的报错。
这里只管仓库里**允许被执**的目录：scripts/、tools/ 下带 shebang 的普通文件。
"""

from __future__ import annotations

import stat
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXEC_DIRS = ("scripts", "tools")


def _has_shebang(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


def iter_candidates():
    for rel in EXEC_DIRS:
        base = ROOT / rel
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            if "__pycache__" in path.parts:
                continue
            if _has_shebang(path):
                yield path


class ScriptModeTests(unittest.TestCase):
    def test_every_script_with_shebang_is_executable(self):
        offenders = [
            str(p.relative_to(ROOT))
            for p in iter_candidates()
            if not p.stat().st_mode & stat.S_IXUSR
        ]
        self.assertEqual(
            offenders,
            [],
            "下列脚本带 shebang 但没有可执行位（chmod +x 后重新提交）：\n  "
            + "\n  ".join(offenders),
        )

    def test_candidates_are_not_empty(self):
        # 反证守卫：目录改名或扫描逻辑写错时，用例会「扫不到东西」而假绿。
        self.assertGreater(len(list(iter_candidates())), 10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
