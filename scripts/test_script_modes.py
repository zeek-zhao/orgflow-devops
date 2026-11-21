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

    def test_renamed_scripts_have_no_stale_references(self):
        """反证另一面：脚本改名后，任何文件里都不能再出现旧路径。

        tests/harness/entrypoint.sh 里的脚本路径是烧进 m0-test 镜像的
        （COPY tests/harness/entrypoint.sh），改了名字而这里漏改，CI 会红在
        「No such file or directory」——这次真机就是被它卡住的。
        """
        import re

        old = re.findall(r"(?<![-\w])(?:gen-agent-key|ca-install|gen-hosts|init|backup|restore|"
                         r"nexus-deploy|nexus-backup|nexus-setup-repos|pin-images|doctor|"
                         r"cve-scan|gen-sbom|render-dex|gen-jjb-conf|jenkins-cli|"
                         r"ldap-set-passwords|gen-ldif-passwords|collect-jenkins-warnings|"
                         r"check-jenkins-warnings)\.(?:sh|py)", "", re.S)
        self.assertEqual(old, [])

        stale = []
        for path in (ROOT / "tests").rglob("*"):
            if not path.is_file() or path.suffix not in {".sh", ".bats", ".py", ".yml"}:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for hit in re.finditer(r"scripts/([a-z0-9-]+)\.(?:sh|py)", text):
                name = hit.group(1)
                if re.match(r"^\d", name):
                    continue  # 已编号
                stale.append(f"{path.relative_to(ROOT)}: scripts/{hit.group(0)}")
        self.assertEqual(stale, [], "脚本编号化后出现旧名引用：\n  " + "\n  ".join(stale))

    def test_candidates_are_not_empty(self):
        # 反证守卫：目录改名或扫描逻辑写错时，用例会「扫不到东西」而假绿。
        self.assertGreater(len(list(iter_candidates())), 10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
