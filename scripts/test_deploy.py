import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("scripts/deploy.sh", "scripts/doctor.py", ".env.example",
                     "services/router/render.py", "config/routes.yaml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("ENV_FILE", "ENV_NAME", "COMPOSE", "CADDY_ADMIN_URL",
                                   "SERVICE_VERSION", "SERVICE_PORT", "SERVICE_DOMAIN",
                                   "GATEWAY_PORT", "DEPLOY_HEALTH_TIMEOUT", "DEPLOY_POLL_INTERVAL")}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}",
                        DEPLOY_HEALTH_TIMEOUT="1", DEPLOY_POLL_INTERVAL="1")
        mock = f"""#!{sys.executable}
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
with open("calls.jsonl", "a") as log:
    log.write(json.dumps([tool, *args]) + "\\n")
if tool == "curl":
    print(os.environ.get("TEST_PING", "200") if args[-1].endswith("/auth/ping") else "302")
elif args[0] == "inspect":
    calls = [json.loads(line) for line in Path("calls.jsonl").read_text().splitlines()]
    if (os.environ.get("TEST_FINAL_FAILURE") and args[-1] == "container-ldap"
            and len([call for call in calls if "up" in call]) == 8):
        print("running unhealthy")
    else:
        print(os.environ.get("TEST_HEALTH", "running healthy"))
elif "config" in args:
    if os.environ.get("TEST_CONFIG_FAIL"):
        print(os.environ["TEST_CONFIG_FAIL"], file=sys.stderr)
        sys.exit(1)
    env_file = Path(args[args.index("--env-file") + 1])
    values = dict(line.split("=", 1) for line in env_file.read_text().splitlines()
                  if "=" in line and not line.startswith("#"))
    port = os.environ.get("GATEWAY_PORT", values.get("GATEWAY_PORT", "8080"))
    print(json.dumps({{"name": "orgflow-devops", "services": {{
        "jenkins": {{"environment": values, "command": None}},
        "caddy": {{"ports": [{{"target": 8080, "published": port}}]}}
    }}}}))
elif "up" in args and args[-1] == os.environ.get("TEST_FAIL_SERVICE"):
    print("image pull failed: " + args[-1])
    sys.exit(23)
elif "logs" in args:
    print("test log tail " + os.environ.get("TEST_LOG_SECRET", ""))
elif "ps" in args and "-q" in args:
    print("container-" + args[-1])
elif "ps" in args and "--format" in args:
    print("[]")
elif "info" in args:
    print(json.dumps(str(Path.cwd())))
elif "--version" in args or "version" in args:
    print("test version")
"""
        for name in ("docker", "curl"):
            path = self.bin / name
            path.write_text(mock)
            path.chmod(0o755)

    def deploy(self, **env):
        return subprocess.run(
            ["bash", "scripts/deploy.sh"], cwd=self.root, env=dict(self.env, **env),
            capture_output=True, text=True, timeout=20,
        )

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_clean_bootstrap_and_batch_order(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.root / ".env"
        values = dict(line.split("=", 1) for line in path.read_text().splitlines()
                      if "=" in line and not line.startswith("#"))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        for key in ("JENKINS_ADMIN_PASSWORD", "LDAP_ADMIN_PASSWORD", "OAUTH2_CLIENT_SECRET"):
            self.assertEqual(len(bytes.fromhex(values[key])), 32)
        self.assertEqual(len(values["OAUTH2_COOKIE_SECRET"].encode("ascii")), 32)
        for key, value in values.items():
            if "PASSWORD" in key or "SECRET" in key:
                self.assertNotIn(value, result.stdout + result.stderr)
        calls = self.calls()
        self.assertEqual([call[-1] for call in calls if "up" in call],
                         ["ldap", "dex", "oauth2-proxy", "router", "caddy",
                          "jenkins", "nexus", "ldapadmin"])
        for first, following in (("ldap", "dex"), ("oauth2-proxy", "router"),
                                 ("caddy", "jenkins")):
            health = next(i for i, call in enumerate(calls)
                          if call[1] == "inspect" and call[-1] == f"container-{first}")
            start = next(i for i, call in enumerate(calls)
                         if "up" in call and call[-1] == following)
            self.assertLess(health, start)
        self.assertIn("端点自检通过: /jenkins = 302", result.stdout)
        self.assertIn("Jenkins 管理员密码在 .env 的 JENKINS_ADMIN_PASSWORD", result.stdout)

    def test_existing_env_preserved_and_gateway_from_compose(self):
        path = self.root / ".env"
        path.write_text("GATEWAY_PORT=18080\nJENKINS_ADMIN_PASSWORD='literal$(touch injected)'\n")
        previous = path.read_bytes()
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), previous)
        self.assertFalse((self.root / "injected").exists())
        self.assertNotIn("已生成随机密钥", result.stdout)
        self.assertIn("http://localhost:18080", result.stdout)

    def test_pull_failure_identifies_service_and_logs(self):
        result = self.deploy(TEST_FAIL_SERVICE="nexus")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image pull failed: nexus", result.stdout)
        self.assertIn("相关服务: nexus", result.stderr)
        self.assertIn("test log tail", result.stderr)
        self.assertTrue(any("logs" in call and call[-2:] == ["--tail=50", "nexus"]
                            for call in self.calls()))
        self.assertNotIn("部署完成", result.stdout)

    def test_health_failure_never_uses_auth_redirect_as_readiness(self):
        for health in ("running starting", "running unhealthy",
                       "running missing-healthcheck", "exited unhealthy"):
            with self.subTest(health=health):
                result = self.deploy(TEST_HEALTH=health)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ldap", result.stderr)
                self.assertIn("test log tail", result.stderr)
                self.assertFalse(any(call[0] == "curl" for call in self.calls()))
                self.assertNotIn("部署完成", result.stdout)

    def test_logs_redact_credentials(self):
        secret = "private-test-value-123"
        (self.root / ".env").write_text(f"LDAP_ADMIN_PASSWORD={secret}\n")
        result = self.deploy(TEST_FAIL_SERVICE="ldap", TEST_LOG_SECRET=secret)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[REDACTED]", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_wrong_endpoint_status_is_failure(self):
        result = self.deploy(TEST_PING="302")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("预期 200，实际 302", result.stderr)
        self.assertNotIn("部署完成", result.stdout)

    def test_final_barrier_detects_earlier_service_failure(self):
        result = self.deploy(TEST_FINAL_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ldap: running unhealthy", result.stderr)
        self.assertFalse(any(call[0] == "curl" for call in self.calls()))

    def test_config_error_does_not_expose_secret(self):
        secret = "malformed-secret-123"
        result = self.deploy(TEST_CONFIG_FAIL=secret)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Compose 配置解析失败", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_doctor_is_read_only(self):
        result = subprocess.run(
            [sys.executable, "scripts/doctor.py"], cwd=self.root,
            env=dict(self.env, GATEWAY_PORT="0"),
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("只读，不启动容器", result.stdout)
        self.assertIn(".env 不存在", result.stdout)
        self.assertFalse((self.root / ".env").exists())
        for call in self.calls():
            self.assertFalse(set(call) & {"up", "run", "start", "pull", "build"})


if __name__ == "__main__":
    unittest.main()
