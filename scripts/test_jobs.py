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
        for directory in ("scripts", "config", "services/router", "services/auth/dex",
                          "tests", "bin"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for name in (
            "scripts/gen-jjb-conf.sh", "scripts/deploy.sh", "scripts/backup.sh",
            "scripts/backup-common.sh", "scripts/render-dex.sh",
            # backup.sh 对 nexus 包做内容级门禁（#93），临时根里必须也有这个脚本，
            # 否则 --all 备份会在「找不到 check_nexus_archive.py」处失败。
            "scripts/check_nexus_archive.py",
            # deploy.sh 在任何 compose 调用前都会先备好 agent 密钥（#45）
            "scripts/gen-agent-key.sh",
            "config/jenkins_jobs.ini.tpl", "config/routes.yaml",
            "services/router/render.py", "services/auth/dex/config.yaml.tmpl",
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
        # 普通字符串拼接而非 f-string：下面的 mock 里全是字典/JSON 花括号，
        # 用 f-string 得把每个 { } 都写成 {{ }}，改一处漏一处就是语法错。
        mock = "#!" + sys.executable + """
import io
import json
import os
from pathlib import Path
import sys
import tarfile

args = sys.argv[1:]

# deploy.sh 现在先解析 compose 拿网关域名与端口（ADR-13），
# 这一步必须返回合法 JSON，否则后面的部署逻辑根本没机会跑。
config = None
if args[:1] == ["compose"] and "config" in args and "--format" in args:
    env_file = Path(args[args.index("--env-file") + 1])
    values = {}
    if env_file.is_file():
        values = dict(
            line.split("=", 1) for line in env_file.read_text().splitlines()
            if "=" in line and not line.startswith("#")
        )
    config = {
        "name": "orgflow-devops",
        "services": {
            "router": {"environment": values, "command": None},
            "caddy": {"ports": [
                {"target": 80, "published": values.get("GATEWAY_HTTP_PORT", "80")},
                {"target": 443, "published": values.get("GATEWAY_HTTPS_PORT", "443")},
            ]},
        },
    }

with open(os.environ["JOB_TEST_LOG"], "a") as log:
    log.write(json.dumps({
        "tool": Path(sys.argv[0]).name,
        "args": args,
        "version": os.environ.get("JENKINS_VERSION"),
        "port": config["services"]["caddy"]["ports"][0]["published"] if config else None,
    }) + "\\n")

if config is not None:
    print(json.dumps(config))
    sys.exit(0)
if args[:2] == ["volume", "inspect"]:
    sys.exit(int(os.environ.get("JOB_TEST_INSPECT_STATUS", "0")))
if os.environ.get("JOB_TEST_STATUS", "0") == "0" and args[:1] == ["run"]:
    members = [("data", b"test data")]
    # Nexus 的数据分 db/ 与 blobs/ 两处（#93），备份脚本会做内容级门禁，
    # 所以假 docker 要按真实卷的形状产出；JOB_TEST_NEXUS_DB_ONLY=1 用来造
    # 「只备 db 不备 blobs」的残缺包，验证门禁确实会红。
    if any(a.endswith("orgflow-devops_nexus_data:/data:ro") for a in args):
        if os.environ.get("JOB_TEST_NEXUS_DB_ONLY") == "1":
            members = [("db/nexus.mv.db", b"H2" * 64)]
        else:
            members = [
                ("db/nexus.mv.db", b"H2" * 64),
                ("blobs/default/metadata.properties", b"blobStoreName=default\\n"),
                ("blobs/default/content/x.bin", b"\\x00\\x01" * 32),
            ]
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as archive:
        for name, data in members:
            info = tarfile.TarInfo(name)
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

    def deploy_calls(self):
        """去掉 deploy.sh 开头的 compose config 探测，只看真正的部署动作。"""
        return [call for call in self.commands() if "config" not in call["args"]]

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

    def test_conf_url_defaults_to_internal_jenkins(self):
        """#30：JJB 走 compose 内网直连。没有 JJB_JENKINS_URL 的旧 .env
        （甚至带着对外地址 JENKINS_URL）也必须生成内网地址，不再要求宿主解析域名。"""
        result = self.run_script("gen-jjb-conf")
        self.assertEqual(result.returncode, 0, result.stderr)
        parser = configparser.ConfigParser()
        parser.read(self.root / ".jjb/jenkins_jobs.ini")
        self.assertEqual(parser["jenkins"]["url"], "http://jenkins:8080/")
        self.assertNotIn("org-devops.com", parser["jenkins"]["url"])
        # 显式声明优先于默认值
        self.dotenv.write_text(
            "JJB_JENKINS_URL=http://jjb-direct:8080/\n"
            "JENKINS_URL=https://jenkins.org-devops.com/\n"
            "JENKINS_ADMIN_ID=admin\nJENKINS_ADMIN_PASSWORD=secret\n"
        )
        self.assertEqual(self.run_script("gen-jjb-conf").returncode, 0)
        parser = configparser.ConfigParser()
        parser.read(self.root / ".jjb/jenkins_jobs.ini")
        self.assertEqual(parser["jenkins"]["url"], "http://jjb-direct:8080/")

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

    def test_conf_ldap_service_account_makes_jobs_work_out_of_the_box(self):
        """#140 / #86：全新部署的 .env 只有 ORGFLOW_INITIAL_PASSWORD，
        Jenkins 是 LDAP-only realm、本地 admin 不存在。JJB 必须自动改用
        svc-platform-admin + 初始口令，否则 make jobs 首次必然 401。
        反证：删掉 gen-jjb-conf.sh 里的 LDAP 回退，这条必须红。"""
        self.dotenv.write_text(
            "JENKINS_URL=https://jenkins.org-devops.com/\n"
            "ORGFLOW_INITIAL_PASSWORD=TESTONLY_INITIAL_PW_140\n"
        )
        result = self.run_script("gen-jjb-conf")
        self.assertEqual(result.returncode, 0, result.stderr)
        parser = configparser.ConfigParser()
        parser.read(self.root / ".jjb/jenkins_jobs.ini")
        self.assertEqual(parser["jenkins"]["user"], "svc-platform-admin")
        self.assertEqual(parser["jenkins"]["password"], "TESTONLY_INITIAL_PW_140")
        self.assertEqual(parser["jenkins"]["url"], "http://jenkins:8080/")

    def test_conf_explicit_jjb_credentials_take_precedence(self):
        """显式 JJB_USER/JJB_PASSWORD 优先于初始口令（运维换专用服务账号）。
        反证：只给这两个键、去掉归一化到模板键的赋值，必填校验会误报缺变量。"""
        self.dotenv.write_text(
            "ORGFLOW_INITIAL_PASSWORD=TESTONLY_INITIAL_PW_140\n"
            "JJB_USER=custom-admin\n"
            "JJB_PASSWORD=TESTONLY_CUSTOM_PW_140\n"
        )
        result = self.run_script("gen-jjb-conf")
        self.assertEqual(result.returncode, 0, result.stderr)
        parser = configparser.ConfigParser()
        parser.read(self.root / ".jjb/jenkins_jobs.ini")
        self.assertEqual(parser["jenkins"]["user"], "custom-admin")
        self.assertEqual(parser["jenkins"]["password"], "TESTONLY_CUSTOM_PW_140")

    def test_conf_without_any_credentials_fails_closed(self):
        """既没有初始口令也没有 JENKINS_ADMIN_* 时必须失败，不能放行空凭据。"""
        self.dotenv.write_text("JENKINS_URL=https://jenkins.org-devops.com/\n")
        result = self.run_script("gen-jjb-conf")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺少必填变量", result.stderr)
    def test_deploy_selected_service(self):
        # #46：SERVICE_VERSION 已停用（唯一支持版本覆盖的 nexus 移出了 compose），
        # 单服务部署只按服务名走。
        result = self.run_script("deploy", "--service", "caddy")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.deploy_calls()
        self.assertEqual(commands[0]["args"], [
            "compose", "--env-file", ".env", "up", "-d", "--no-deps", "caddy",
        ])
        self.assertIsNone(commands[0]["version"])
        self.assertEqual(commands[1]["args"][-2:], ["ps", "caddy"])

    def test_deploy_rejects_service_version(self):
        # 传了却什么都不发生，是排查时最贵的一种"成功"
        result = self.run_script(
            "deploy", "--service", "caddy", SERVICE_VERSION="3.92.2",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SERVICE_VERSION 已停用", result.stderr)
        # 前置校验就该退出：一条 docker 命令都不该跑过
        self.assertFalse(self.log.exists())

    def test_deploy_rejects_nexus(self):
        # #46：nexus 移出 compose，必须指向 job，而不是静默 no-op
        result = self.run_script("deploy", "--service", "nexus")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nexus-deploy", result.stderr)
        self.assertFalse(self.log.exists())

    def test_deploy_environment_file_carries_the_gateway_port(self):
        # ADR-13 起端口不再是部署参数：唯一的入口是环境文件里的 GATEWAY_HTTP_PORT
        (self.root / ".env.staging").write_text(
            self.dotenv.read_text() + "GATEWAY_HTTP_PORT=8088\n"
        )
        result = self.run_script(
            "deploy", "--service", "caddy", ENV_NAME="staging",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.commands()[0]
        self.assertEqual(first["args"][2], ".env.staging")
        self.assertEqual(first["port"], "8088")

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
        # compose config 探测成功，真正的 up 失败：退出码必须原样透出
        self.assertEqual(result.returncode, 23)
        self.assertEqual(len(self.commands()), 2)
        self.assertIn("config", self.commands()[0]["args"])

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

    def test_backup_nexus_rejects_database_only_archive(self):
        """#93 反证：只备 db 不备 blob store 的包必须被判红且不发布。"""
        result = self.run_script("backup", "--service", "nexus",
                                 JOB_TEST_NEXUS_DB_ONLY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("内容不完整", result.stderr)
        directory = self.root / "out/backups"
        self.assertEqual(sorted(p.name for p in directory.glob("nexus-*.tgz")), [])

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


class NexusJobDefinitionTests(unittest.TestCase):
    """#46 的静态约束。

    这些关系一旦漂了，只有「真机上把 job 跑一遍」才会暴露 —— 而真机验证
    是最慢、最容易被跳过的环节。能静态钉死的就别留给真机。
    """

    def test_image_digest_matches_images_lock(self):
        rows = {}
        for line in (ROOT / "tests/images.lock").read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            name, ref, digest = line.split("\t")
            rows[name] = (ref, digest)
        ref, digest = rows["nexus"]
        tag = ref.split(":", 1)[1]
        script = (ROOT / "scripts/nexus-deploy.sh").read_text(encoding="utf-8")
        # 213 拉不到 Docker Hub，所以脚本必须指向 GHCR 的 mirror 包；
        # 但 digest 必须和 images.lock 一致，否则「nexus 跑的是哪个版本」有两个真源。
        self.assertIn(f"mirror-nexus:{tag}@{digest}", script)

    def test_job_runs_on_the_docker_agent_through_the_shared_library(self):
        text = (ROOT / "config/job_definitions/nexus/nexus-deploy.yaml").read_text(encoding="utf-8")
        # 双花括号是 JJB 模板的转义形式（渲染后是单花括号），故意按渲染前断言。
        # #91：从 node('orgflow-docker') { } 块改成 declarative pipeline 的 agent label，
        # 语义不变（仍跑在 orgflow-docker 这个可信 agent 上），所以断言改成新写法，
        # 并顺带把「declarative + 至少两个 stage」也断言上 —— 是收紧不是放宽。
        self.assertIn("agent {{ label 'orgflow-docker' }}", text)
        self.assertIn("pipeline {{", text)
        self.assertGreaterEqual(text.count("stage("), 2)
        self.assertIn("deployNexus(", text)
        self.assertNotIn("docker run", text)  # 部署逻辑在脚本里，job 只负责调度

    def test_deploy_service_no_longer_offers_nexus(self):
        groovy = (ROOT / "shared-library/vars/deployService.groovy").read_text(encoding="utf-8")
        self.assertNotIn("'nexus'", groovy)
        job = (ROOT / "config/job_definitions/deploy/deploy-service.yaml").read_text(encoding="utf-8")
        self.assertNotIn("- nexus\n", job)

    def test_network_and_volume_names_stay_aligned(self):
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        script = (ROOT / "scripts/nexus-deploy.sh").read_text(encoding="utf-8")
        backup = (ROOT / "scripts/backup-common.sh").read_text(encoding="utf-8")
        # compose 显式把网络命名成 orgflow（不是默认的 <project>_orgflow），
        # 所以脚本里写 orgflow 是对的；哪天改成默认命名，这条会红。
        self.assertIn("  orgflow:\n    name: orgflow\n", compose)
        # 卷名 = <项目名>_nexus_data，三处必须一致
        self.assertIn("name: orgflow-devops\n", compose)
        self.assertIn("orgflow-devops_nexus_data", script)
        self.assertIn("orgflow-devops_nexus_data", backup)

    def test_nexus_password_is_injected_as_a_credential(self):
        groovy = (ROOT / "shared-library/vars/deployNexus.groovy").read_text(encoding="utf-8")
        self.assertIn("credentialsId: 'nexus-admin-password'", groovy)
        self.assertIn("set +x", groovy)
        # 密码绝不能作为参数或内联到命令里
        self.assertNotIn("$NEXUS_ADMIN_PASSWORD", groovy)
        jcasc = (ROOT / "config/jenkins.yaml").read_text(encoding="utf-8")
        self.assertIn('id: "nexus-admin-password"', jcasc)


if __name__ == "__main__":
    unittest.main()
