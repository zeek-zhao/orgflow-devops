"""scripts/check-image-source.sh 的行为测试（#131 镜像单一来源 / #134 期望值溯源）。

闸门要防的是「看起来成功的失败」：改了 Dockerfile 没等 CI、直接部署，
Compose 拉到上一版镜像、健康检查全绿、跑的却是旧代码。所以每一条拦截路径
都配一条放行路径 —— 只证明「正常时放行」等于什么都没证明。

这里**不用 git 桩**，而是建一个真仓库跑真 git：闸门的核心判据就是
「自 pinned-at 以来镜像上下文有没有变过」，用桩回答这个问题的测试，
测到的是桩而不是判据。代价是每个用例 init 一次仓库（几十毫秒）。
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = "scripts/check-image-source.sh"
FIXTURES = ("docker-compose.ghcr.yml", "tests/images.lock")

# 与 .github/workflows/images.yml 的 paths 一致；改这些就要重编镜像
CONTEXTS = ("tests/harness", "services/router", "services/dnsmasq", "services/jenkins",
            "tools/jjb", "tools/jenkins", "tools/jenkins-agent",
            ".github/workflows/images.yml", ".github/scripts")

GIT = ["git", "-c", "user.name=guard-test", "-c", "user.email=guard@example.invalid"]


class ImageSourceGuardTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in FIXTURES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        for context in CONTEXTS:
            sample = self.root / context / "probe.txt"
            sample.parent.mkdir(parents=True, exist_ok=True)
            sample.write_text("fixture\n")
        (self.root / "scripts").mkdir()
        shutil.copyfile(ROOT / SCRIPT, self.root / SCRIPT)
        (self.root / "README.md").write_text("# fixture\n")

        self.env = dict(os.environ)
        for key in ("USE_GHCR", "PINNED_AT_SHA"):
            self.env.pop(key, None)

    # ── 仓库搭建 ────────────────────────────────────────────────────────
    def git(self, *args, check=True):
        return subprocess.run(GIT + list(args), cwd=self.root, capture_output=True,
                              text=True, check=check)

    def init_repo(self):
        """两次提交：先落源码，再把 pinned-at 指向第一次提交。

        这就是真实时序：digest 由「某次构建」产出，pinned-at 记的是那次提交，
        而写 pinned-at 这个动作本身在它之后。
        """
        self.git("init", "-q")
        # 换行符归一化会让 probe 文件「看起来被改过」，把闸门的判据搞脏：
        # 这里要测的是「镜像上下文有没有改」，不是 git 的行尾转换。
        self.git("config", "core.autocrlf", "false")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "fixtures")
        built_at = self.git("rev-parse", "HEAD").stdout.strip()
        overlay = self.root / "docker-compose.ghcr.yml"
        overlay.write_text(re.sub(r"^# pinned-at:.*$", f"# pinned-at: {built_at}",
                                  overlay.read_text(), count=1, flags=re.MULTILINE))
        self.git("add", "docker-compose.ghcr.yml")
        self.git("commit", "-q", "-m", "pin")
        return built_at

    def run_guard(self, **env):
        # 变量必须**在 shell 内**赋值，不能靠 env= 传：
        # 这里的 `bash` 可能落到 C:////Windows////System32////bash.exe（WSL），
        # 而 WSL 只转发 WSLENV 里列出的变量，其余 Windows 环境变量会被静默丢掉
        # —— 表现成 test 里设的 USE_GHCR=0 到不了脚本，脚本照旧走 GHCR 分支。
        prefix = "".join(f"{key}={value} " for key, value in env.items())
        return subprocess.run(["bash", "-c", f"{prefix}bash {SCRIPT}"], cwd=self.root,
                              env=self.env, capture_output=True, text=True, timeout=60)

    def edit(self, name, transform):
        path = self.root / name
        path.write_text(transform(path.read_text()))

    # ── 放行路径 ────────────────────────────────────────────────────────
    def test_pinned_and_unchanged_passes(self):
        self.init_repo()
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("镜像来源：GHCR", result.stdout)
        self.assertIn("pinned-at=", result.stdout)

    def test_documentation_change_does_not_block_deployment(self):
        # 这条是闸门可用性的底线：判据若退化成「HEAD 是否等于 origin/main」，
        # 每次改文档都会误报，人就会学会无视它 —— 那比没有闸门更糟。
        self.init_repo()
        (self.root / "README.md").write_text("# 改了一行说明\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_local_build_mode_is_explicitly_allowed(self):
        result = self.run_guard(USE_GHCR="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("本地构建", result.stdout)
        # 必须说清代价，否则这条路径会被当成等价选项
        self.assertIn("共享环境", result.stdout)

    def test_missing_git_metadata_degrades_with_warning(self):
        # zip 下载的副本没有 .git：digest 与它自己的源码同批产出，无从比较。
        # 只能是警告，否则公开仓最常见的打开方式直接不能部署。
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("没有 .git 元数据", result.stdout)

    # ── 拦截路径（每条都要有反证）──────────────────────────────────────
    def test_missing_pinned_at_fails(self):
        self.init_repo()
        self.edit("docker-compose.ghcr.yml",
                  lambda text: "\n".join(line for line in text.splitlines()
                                         if not line.startswith("# pinned-at:")) + "\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("pinned-at", result.stderr)

    def test_unresolvable_pinned_at_fails(self):
        self.init_repo()
        self.edit("docker-compose.ghcr.yml",
                  lambda text: re.sub(r"^# pinned-at:.*$", "# pinned-at: " + "b" * 40,
                                      text, count=1, flags=re.MULTILINE))
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("找不到提交", result.stderr)

    def test_committed_image_change_fails(self):
        self.init_repo()
        (self.root / "services/jenkins/Dockerfile").write_text("FROM scratch\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change image")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("已提交未构建", result.stderr)
        self.assertIn("services/jenkins/Dockerfile", result.stderr)

    def test_uncommitted_image_change_fails(self):
        self.init_repo()
        (self.root / "services/router/render.py").write_text("# 改了但没提交\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("工作区未提交", result.stderr)

    def test_pin_placeholder_fails(self):
        self.init_repo()
        self.edit("tests/images.lock",
                  lambda text: text + "jenkins-agent\tghcr.io/zeek-zhao/orgflow-devops/"
                                      "jenkins-agent:24.04-v1\t待构建后回填\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("待构建后回填", result.stderr)

    def test_floating_tag_fails(self):
        # 浮动 tag（没有 @sha256）会在不同机器上拉到不同镜像，部署不可复现。
        self.init_repo()
        self.edit("docker-compose.ghcr.yml",
                  lambda text: re.sub(r"(/router:)[^@\s]+@sha256:[a-f0-9]{64}", r"\g<1>latest",
                                      text, count=1))
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("未按 digest 锁定", result.stderr)

    def test_error_message_names_the_recovery_steps(self):
        self.init_repo()
        (self.root / "tools/jjb/Dockerfile").write_text("FROM scratch\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change jjb")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        for step in ("合并到 main", "Images 工作流", "make images-pin"):
            self.assertIn(step, result.stderr)


if __name__ == "__main__":
    unittest.main()
