import configparser
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class JobScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for directory in ("scripts", "config", "services/router", "tests", "bin"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for name in (
            "scripts/gen-jjb-conf.sh", "scripts/deploy.sh", "scripts/backup.sh",
            "scripts/backup-common.sh",
            "config/jenkins_jobs.ini.tpl", "config/routes.yaml",
            "services/router/render.py",
            "tests/images.lock",
        ):
            shutil.copyfile(ROOT / name, self.root / name)
        self.dotenv = self.root / ".env"
        self.dotenv.write_text(
            "JENKINS_URL=https://jenkins.org-devops.com/\n"
            "JENKINS_ADMIN_ID=admin\n"
            "JENKINS_ADMIN_PASSWORD='test-only% # $literal'\n"
        )
        self.log = self.root / "commands.jsonl"
        self.env = {
            key: value for key, value in os.environ.items()
            if key not in (
                "ENV_FILE", "ENV_NAME", "SERVICE_VERSION", "SERVICE_PORT",
                "SERVICE_DOMAIN", "BACKUP_TARGET", "BACKUP_DIR",
                "BACKUP_RETENTION_DAYS", "CADDY_ADMIN_URL",
            )
        }
        self.env.update(
            PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
            JOB_TEST_LOG=str(self.log),
        )
        mock = f"""#!{sys.executable}
import json
import io
import os
from pathlib import Path
import sys
import tarfile
with open(os.environ["JOB_TEST_LOG"], "a") as log:
    log.write(json.dumps({{
        "tool": Path(sys.argv[0]).name, "args": sys.argv[1:],
        "version": os.environ.get("JENKINS_VERSION"),
        "port": os.environ.get("GATEWAY_PORT"),
    }}) + "\\n")
if sys.argv[1:3] == ["volume", "inspect"]:
    sys.exit(int(os.environ.get("JOB_TEST_INSPECT_STATUS", "0")))
if os.environ.get("JOB_TEST_STATUS", "0") == "0" and sys.argv[1] == "run":
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as archive:
        data = b"test data"
        info = tarfile.TarInfo("data")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
sys.exit(int(os.environ.get("JOB_TEST_STATUS", "0")))
"""
        for name in ("docker", "make"):
            path = self.root / "bin" / name
            path.write_text(mock)
            path.chmod(0o755)

    def run_script(self, name, *args, **env):
        return subprocess.run(
            ["bash", f"scripts/{name}.sh", *args],
            cwd=self.root, env=dict(self.env, **env),
            capture_output=True, text=True, timeout=10,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_conf_literals_permissions_and_no_execution(self):
        result = self.run_script("gen-jjb-conf")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.root / ".jjb/jenkins_jobs.ini"
        parser = configparser.ConfigParser()
        parser.read(path)
        self.assertEqual(parser["jenkins"]["password"], "test-only% # $literal")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertNotIn("test-only", result.stdout + result.stderr)
        self.dotenv.write_text(
            "JENKINS_URL=http://localhost\nJENKINS_ADMIN_ID=admin\n"
            "JENKINS_ADMIN_PASSWORD=$(touch injected)\n"
        )
        self.assertEqual(self.run_script("gen-jjb-conf").returncode, 0)
        self.assertFalse((self.root / "injected").exists())

    def test_conf_missing_or_empty_variables_does_not_replace_previous(self):
        self.assertEqual(self.run_script("gen-jjb-conf").returncode, 0)
        path = self.root / ".jjb/jenkins_jobs.ini"
        previous = path.read_bytes()
        for content in (
            "", "JENKINS_ADMIN_ID=admin\n",
            "JENKINS_URL=http://localhost\nJENKINS_ADMIN_ID=admin\n"
            "JENKINS_ADMIN_PASSWORD=\n",
        ):
            with self.subTest(content=content):
                self.dotenv.write_text(content)
                result = self.run_script("gen-jjb-conf")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("缺少必填变量", result.stderr)
                self.assertEqual(path.read_bytes(), previous)
        self.dotenv.unlink()
        self.assertNotEqual(self.run_script("gen-jjb-conf").returncode, 0)

    def test_deploy_selected_service_and_version(self):
        result = self.run_script(
            "deploy", "--service", "jenkins", SERVICE_VERSION="lts-jdk17",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(commands[0]["args"], [
            "compose", "--env-file", ".env", "up", "-d", "--no-deps", "jenkins",
        ])
        self.assertIsNone(commands[0]["version"])
        self.assertEqual(commands[1]["args"][-2:], ["ps", "jenkins"])

    def test_deploy_environment_and_port(self):
        shutil.copyfile(self.dotenv, self.root / ".env.staging")
        result = self.run_script(
            "deploy", "--service", "caddy", ENV_NAME="staging", SERVICE_PORT="8088",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands()[0]["args"][2], ".env.staging")
        self.assertEqual(self.commands()[0]["port"], "8088")

    def test_deploy_invalid_parameters_fail_before_docker(self):
        for args, env in (
            (["--service"], {}),
            (["--unknown"], {}),
            (["--service", "not-a-service"], {}),
            (["--service", "jenkins"], {"ENV_NAME": "prod"}),
            (["--service", "caddy"], {"SERVICE_PORT": "0"}),
            (["--service", "caddy"], {"SERVICE_PORT": "65536"}),
            (["--service", "jenkins"], {"SERVICE_PORT": "8088"}),
            (["--service", "router"], {"SERVICE_VERSION": "latest"}),
            (["--service", "jenkins"], {"SERVICE_VERSION": "$(bad)"}),
            (["--service", "jenkins"], {"SERVICE_VERSION": "latest"}),
            (["--service", "caddy"], {"SERVICE_DOMAIN": "example.test"}),
        ):
            with self.subTest(args=args, env=env):
                result = self.run_script("deploy", *args, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())

    def test_push_jobs_only_invokes_make(self):
        result = self.run_script("deploy", "--push-jobs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [{
            "tool": "make", "args": ["jobs"], "version": None, "port": None,
        }])
        self.assertFalse((self.root / "out").exists())

    def test_deploy_docker_failure_is_fatal(self):
        result = self.run_script(
            "deploy", "--service", "router", JOB_TEST_STATUS="23",
        )
        self.assertEqual(result.returncode, 23)
        self.assertEqual(len(self.commands()), 1)

    def test_backup_selected_service_and_retention_scope(self):
        directory = self.root / "out/backups"
        directory.mkdir(parents=True)
        for name in ("ldap-old.tgz", "jenkins-old.tgz", "other.tgz"):
            path = directory / name
            path.touch()
            os.utime(path, (0, 0))
        result = self.run_script(
            "backup", "--service", "ldap", BACKUP_RETENTION_DAYS="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(commands[0]["args"], [
            "volume", "inspect", "orgflow-devops_ldap_data",
        ])
        self.assertIn("orgflow-devops_ldap_data:/data:ro", commands[2]["args"])
        self.assertFalse((directory / "ldap-old.tgz").exists())
        self.assertTrue((directory / "jenkins-old.tgz").exists())
        self.assertTrue((directory / "other.tgz").exists())

    def test_backup_all_volumes(self):
        result = self.run_script("backup", "--all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.commands()), 9)

    def test_backup_missing_volume_or_archive_failure_does_not_clean(self):
        for env in (
            {"JOB_TEST_INSPECT_STATUS": "1"}, {"JOB_TEST_STATUS": "23"},
        ):
            with self.subTest(env=env):
                directory = self.root / "out/backups"
                directory.mkdir(parents=True, exist_ok=True)
                old = directory / "ldap-old.tgz"
                old.touch()
                os.utime(old, (0, 0))
                result = self.run_script("backup", "--service", "ldap", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(old.exists())
                self.log.unlink()

    def test_backup_rejects_invalid_input_before_docker(self):
        for args, env in (
            (["--service"], {}),
            (["--service", "other"], {}),
            (["--unknown"], {}),
            (["--all", "extra"], {}),
            (["--all"], {"BACKUP_TARGET": "nexus"}),
            (["--all"], {"BACKUP_RETENTION_DAYS": "-1"}),
            (["--all"], {"BACKUP_RETENTION_DAYS": "7; echo bad"}),
        ):
            with self.subTest(args=args, env=env):
                result = self.run_script("backup", *args, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
