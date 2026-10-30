import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DIGEST = "sha256:" + "a" * 64


class ImageTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ("scripts/pin-images.sh", "tests/images.sh", "tests/images.lock",
                     "docker-compose.yml", "docker-compose.ghcr.yml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        binary = self.root / "bin"
        binary.mkdir()
        self.env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                        ALLOW_PULL_DOCKER_HUB="0", USE_GHCR="0")
        mock = binary / "docker"
        mock.write_text(f"""#!{sys.executable}
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with open("calls.jsonl", "a") as stream:
    stream.write(json.dumps(args) + "\\n")
if args[:3] == ["buildx", "imagetools", "inspect"]:
    if os.environ.get("INSPECT_FAIL") == args[-1].split("/")[-1].split(":")[0]:
        print("registry access denied", file=sys.stderr)
        sys.exit(1)
    if os.environ.get("BAD_DIGEST"):
        print("Digest: invalid")
    else:
        print("Digest: {DIGEST}")
        print("Manifests:\\n  Name: child@sha256:" + "b" * 64)
elif args[:2] == ["image", "inspect"]:
    sys.exit(1)
elif "config" in args and "--format" in args:
    print(os.environ.get("COMPOSE_JSON", '{{"services": {{}}}}'))
elif "config" in args and os.environ.get("CONFIG_FAIL"):
    sys.exit(1)
elif args and args[0] == "pull" and os.environ.get("PULL_FAIL"):
    sys.exit(1)
""")
        mock.chmod(0o755)

    def run_script(self, script, *args, **env):
        return subprocess.run(
            ["bash", script, *args], cwd=self.root, env=dict(self.env, **env),
            capture_output=True, text=True, timeout=20,
        )

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_hub_missing_fails_fast_by_default(self):
        result = self.run_script("tests/images.sh", "ensure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Docker Hub is unavailable. Import this exact image", result.stderr)
        self.assertFalse(any(call[0] == "pull" for call in self.calls()))

    def test_ci_explicitly_pulls_every_locked_image(self):
        result = self.run_script("tests/images.sh", "ensure", ALLOW_PULL_DOCKER_HUB="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = [f"{ref}@{digest}" for line in (self.root / "tests/images.lock").read_text().splitlines()
                    if not line.startswith("#") for _, ref, digest in [line.split("\t")]]
        self.assertEqual([call[-1] for call in self.calls() if call[0] == "pull"], expected)
        self.assertEqual(self.calls()[-1], ["compose", "build", "router"])

    def test_failed_pull_is_not_hidden(self):
        result = self.run_script("tests/images.sh", "ensure",
                                 ALLOW_PULL_DOCKER_HUB="1", PULL_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("build" in call for call in self.calls()))

    def test_pin_is_idempotent_and_preserves_upstream_blocks(self):
        path = self.root / "docker-compose.ghcr.yml"
        original = path.read_text()
        lock = (self.root / "tests/images.lock").read_bytes()
        result = self.run_script("scripts/pin-images.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        first = path.read_bytes()
        self.assertTrue(path.read_text().startswith(original.rstrip("\n") + "\n"))
        for name in ("router", "jjb", "m0-test"):
            self.assertIn(f"/{name}:24.04-v1@{DIGEST}", path.read_text())
        self.assertIn("x-m0-test-image:", path.read_text())
        result = self.run_script("scripts/pin-images.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), first)
        self.assertEqual((self.root / "tests/images.lock").read_bytes(), lock)
        self.assertEqual(len([call for call in self.calls() if "inspect" in call]), 6)

    def test_failed_or_invalid_inspect_never_partially_writes(self):
        path = self.root / "docker-compose.ghcr.yml"
        original = path.read_bytes()
        for env in ({"INSPECT_FAIL": "jjb"}, {"BAD_DIGEST": "1"}):
            with self.subTest(env=env):
                result = self.run_script("scripts/pin-images.sh", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("先跑 images.yml 工作流", result.stderr)
                self.assertEqual(path.read_bytes(), original)

    def test_invalid_merged_compose_never_replaces_override(self):
        path = self.root / "docker-compose.ghcr.yml"
        original = path.read_bytes()
        result = self.run_script("scripts/pin-images.sh", CONFIG_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(sorted(p.name for p in self.root.glob("tmp*")), [])

    def test_ghcr_mode_pulls_only_pinned_ghcr_images_without_builds(self):
        router = f"ghcr.io/zeek-zhao/orgflow-devops/router:24.04-v1@{DIGEST}"
        harness = f"ghcr.io/zeek-zhao/orgflow-devops/m0-test:24.04-v1@{DIGEST}"
        config = json.dumps({"services": {"router": {"image": router}},
                             "x-m0-test-image": harness})
        result = self.run_script("tests/images.sh", "ensure", USE_GHCR="1", COMPOSE_JSON=config)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[-1] for call in self.calls() if call[0] == "pull"], [router, harness])
        self.assertFalse(any("build" in call for call in self.calls()))
        for call in self.calls():
            if call[0] == "compose":
                self.assertEqual(call[1:5], ["-f", "docker-compose.yml", "-f", "docker-compose.ghcr.yml"])

    def test_ghcr_mode_requires_pin_before_pull(self):
        result = self.run_script("tests/images.sh", "ensure", USE_GHCR="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("make images-pin", result.stderr)
        self.assertFalse(any(call[0] == "pull" for call in self.calls()))


if __name__ == "__main__":
    unittest.main()
