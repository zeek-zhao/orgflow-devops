import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

# deploy.sh 直接调用的全部文件（域名路由改造后新增 render-dex 相关）
DEPLOY_DEPENDENCIES = (
    "scripts/deploy.sh",
    "scripts/doctor.py",
    "scripts/render-dex.sh",
    "scripts/gen-agent-key.sh",
    ".env.example",
    "services/router/render.py",
    "services/auth/dex/config.yaml.tmpl",
    "config/routes.yaml",
)

# #46：nexus 移出 compose，不再参与分批启动（改由 scripts/nexus-deploy.sh 部署）
UP_ORDER = ["dnsmasq", "ldap", "dex", "oauth2-proxy", "router", "caddy",
            "jenkins", "jenkins-agent", "ldapadmin", "homepage"]


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in DEPLOY_DEPENDENCIES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("ENV_FILE", "ENV_NAME", "COMPOSE", "CADDY_ADMIN_URL",
                                   "SERVICE_VERSION", "SERVICE_PORT", "SERVICE_DOMAIN",
                                   "GATEWAY_DOMAIN",
                                   "GATEWAY_HTTP_PORT", "GATEWAY_HTTPS_PORT",
                                   "DEPLOY_HEALTH_TIMEOUT", "DEPLOY_POLL_INTERVAL")}
        # PATH 分隔符必须按平台取（Windows 是 ';'），否则 mock 命令找不到
        self.env.update(PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
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
    # 域名路由后自检 URL 是 https://auth.<domain>/ping、https://jenkins.<domain>/、
    # https://home.<domain>/ —— 前两个一保一护，第三个是公开站点
    url = args[-1]
    if url.endswith("/ping"):
        print(os.environ.get("TEST_PING", "200"))
    elif "home." in url:
        print("200")
    else:
        print("302")
elif args[0] == "inspect":
    calls = [json.loads(line) for line in Path("calls.jsonl").read_text().splitlines()]
    if (os.environ.get("TEST_FINAL_FAILURE") and args[-1] == "container-ldap"
            and len([call for call in calls if "up" in call]) == {len(UP_ORDER)}):
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
    # 端口可被测试覆盖：doctor 会真 bind，CI 非 root 绑不了 80/443
    ports = os.environ.get("TEST_PUBLISHED_PORTS", "").split()
    http_port = ports[0] if ports else values.get("GATEWAY_HTTP_PORT", "80")
    https_port = ports[1] if len(ports) > 1 else values.get("GATEWAY_HTTPS_PORT", "443")
    print(json.dumps({{"name": "orgflow-devops", "services": {{
        "router": {{"environment": values, "command": None}},
        "caddy": {{"ports": [
            {{"target": 80, "published": http_port}},
            {{"target": 443, "published": https_port}}
        ]}}
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

    def deploy(self, *args, **env):
        return subprocess.run(
            ["bash", "scripts/deploy.sh", *args], cwd=self.root, env=dict(self.env, **env),
            capture_output=True, text=True, timeout=30,
        )

    def calls(self):
        # 前置校验（如废弃变量、Compose 解析失败）会直接 exit，一条外部命令都没调过，
        # 日志文件根本不存在——这不是错误，就是「零调用」。
        log = self.root / "calls.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

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
        self.assertEqual([call[-1] for call in calls if "up" in call], UP_ORDER)
        # dnsmasq 必须最先 healthy：其余容器都把它当 resolver
        for first, following in (("dnsmasq", "ldap"), ("ldap", "dex"),
                                 ("oauth2-proxy", "router"), ("caddy", "jenkins")):
            health = next(i for i, call in enumerate(calls)
                          if call[1] == "inspect" and call[-1] == f"container-{first}")
            start = next(i for i, call in enumerate(calls)
                         if "up" in call and call[-1] == following)
            self.assertLess(health, start)
        # 自检必须带域名（SNI/Host 匹配），而不是旧的路径入口
        self.assertIn("端点自检通过: https://auth.org-devops.com/ping = 200", result.stdout)
        self.assertIn("端点自检通过: https://jenkins.org-devops.com/ = 302", result.stdout)
        self.assertIn("网关端口：HTTP 80 / HTTPS 443", result.stdout)
        self.assertIn("Jenkins 管理员密码在 .env 的 JENKINS_ADMIN_PASSWORD", result.stdout)
        # 域名相关产物落盘
        self.assertIn("https://jenkins.org-devops.com {", (self.root / "out/Caddyfile").read_text())
        self.assertIn("issuer: https://dex.org-devops.com/dex",
                      (self.root / "out/dex/config.yaml").read_text())

    def test_existing_env_preserved_and_gateway_from_compose(self):
        path = self.root / ".env"
        path.write_text("GATEWAY_HTTPS_PORT=18443\n"
                        "JENKINS_ADMIN_PASSWORD='literal$(touch injected)'\n")
        previous = path.read_bytes()
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), previous)
        self.assertFalse((self.root / "injected").exists())
        self.assertNotIn("已生成随机密钥", result.stdout)
        # 端口来自 Compose 解析结果，不是硬编码
        self.assertIn("HTTPS 18443", result.stdout)
        # 非 443 时给人看的入口 URL 必须带端口，否则复制出去打不开
        self.assertIn("https://jenkins.org-devops.com:18443/", result.stdout)

    def test_self_check_url_carries_the_same_port_as_resolve(self):
        """--resolve 是按 host:port 精确匹配的，URL 不带端口就退回真实 DNS。

        只断言输出文案不够：默认 443 时 URL 的隐式端口恰好等于映射端口，
        文案看着完全正确，而真正传给 curl 的地址可能是错的。所以这里断言
        **curl 的实际参数**——resolve 的端口和 URL 的端口必须逐字一致。
        """
        (self.root / ".env").write_text("GATEWAY_HTTPS_PORT=18443\n")
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)

        checked = 0
        for call in self.calls():
            if call[0] != "curl" or "--resolve" not in call:
                continue
            resolve = call[call.index("--resolve") + 1]
            url = call[-1]
            self.assertIn(":18443", resolve, f"--resolve 少了端口: {resolve}")
            self.assertIn(":18443", url, f"URL 里少了端口，curl 会退回真实 DNS: {url}")
            checked += 1
        # auth / jenkins / home 三个站点都走 gw()
        self.assertEqual(checked, 3)

    def test_service_shortcut_accepts_every_compose_service(self):
        """--service 的白名单是手写的，compose 里加了服务忘了加它就直接被拒。

        homepage 当初就是这么漏的：compose 加了、部署批次加了、健康闸门加了，
        唯独这个 case 列表没加，`bash scripts/deploy.sh --service homepage` 退出 1。
        白名单不会随 compose 自动长，所以拿 compose 的服务集合反查。

        `profiles` 里的（目前只有 `jjb`）是一次性工具容器，本来就不该进 --service，
        排除掉而不是把它加进白名单。
        """
        text = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        block = re.search(r"^services:\n(.*?)^[a-z]", text, re.M | re.S).group(1)
        services = {}
        for chunk in re.split(r"^  (?=[a-z][a-z0-9_-]*:$)", block, flags=re.MULTILINE):
            match = re.match(r"([a-z][a-z0-9_-]*):$", chunk, re.MULTILINE)
            if match:
                services[match.group(1)] = chunk
        deployable = [name for name, body in services.items() if "profiles:" not in body]
        self.assertGreaterEqual(len(deployable), 10, f"compose 服务解析异常: {deployable}")
        # --service 不做 .env 自举（那是全量部署的事），所以先备一份
        (self.root / ".env").write_text("GATEWAY_HTTPS_PORT=443\n")
        for name in deployable:
            result = self.deploy("--service", name)
            self.assertEqual(result.returncode, 0, f"--service {name} 被拒: {result.stderr}")

    def test_up_build_flag_follows_image_source(self):
        """USE_GHCR=1 时镜像钉了 digest，`--build` 会拿 digest 当 tag 写，直接报
        `refusing to create a tag with a digest reference`（dnsmasq / router / jjb 都有 build:）。

        这条只能靠真栈或本用例发现：CI 的 harness 是 `compose up --no-build --pull never`
        直连，**从不经过 deploy.sh**，所以整条路径零覆盖。
        """
        result = self.deploy(USE_GHCR="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        ups = [call for call in self.calls() if call[0] == "docker" and "up" in call]
        self.assertTrue(ups, "一次 up 都没发生")
        for call in ups:
            self.assertIn("--no-build", call, f"USE_GHCR=1 却缺 --no-build: {call}")

    def test_up_builds_local_images_by_default(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        ups = [call for call in self.calls() if call[0] == "docker" and "up" in call]
        self.assertTrue(ups, "一次 up 都没发生")
        for call in ups:
            self.assertIn("--build", call, f"默认路径应 --build: {call}")

    def test_service_shortcut_uses_no_build_under_ghcr(self):
        """`--service` 默认不强制构建（沿用 compose 的缺镜像才建），
        但 GHCR 下必须 --no-build，否则和批量路径一样撞 digest 引用。"""
        (self.root / ".env").write_text("GATEWAY_HTTPS_PORT=443\n")
        result = self.deploy("--service", "router", USE_GHCR="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        ups = [call for call in self.calls() if call[0] == "docker" and "up" in call]
        self.assertEqual(len(ups), 1, f"应只 up 一次: {ups}")
        self.assertIn("--no-build", ups[0], f"GHCR 下 --service 缺 --no-build: {ups[0]}")

    def test_gateway_domain_override_flows_into_caddyfile_and_dex(self):
        (self.root / ".env").write_text("GATEWAY_DOMAIN=example.test\n")
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        caddyfile = (self.root / "out/Caddyfile").read_text()
        self.assertIn("https://jenkins.example.test {", caddyfile)
        self.assertIn("https://auth.example.test/oauth2/start", caddyfile)
        self.assertNotIn("org-devops.com", caddyfile)
        dex = (self.root / "out/dex/config.yaml").read_text()
        self.assertIn("issuer: https://dex.example.test/dex", dex)
        self.assertIn("https://auth.example.test/oauth2/callback", dex)
        self.assertNotIn("__DEX_ISSUER__", dex)
        self.assertIn("https://jenkins.example.test/ = 302", result.stdout)

    def test_nexus_is_not_a_compose_service_any_more(self):
        """#46：nexus 移出 compose，`--service nexus` 必须明确报错并指向 job。

        静默接受最坏：调用方以为部署成功了，实际什么都没发生，
        nexus 站点仍然是 502，而日志里一句错误都没有。
        """
        result = self.deploy("--service", "nexus")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nexus-deploy", result.stderr)
        self.assertFalse(any(call[0] == "docker" for call in self.calls()))

    def test_service_version_is_rejected(self):
        """#46：唯一支持版本覆盖的 nexus 移出后，SERVICE_VERSION 没有适用对象。"""
        result = self.deploy("--service", "router", SERVICE_VERSION="3.92.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SERVICE_VERSION 已停用", result.stderr)
        self.assertFalse(any(call[0] == "docker" for call in self.calls()))

    def test_pull_failure_identifies_service_and_logs(self):
        # 用 ldapadmin 而不是 nexus：nexus 已移出 compose（#46），
        # 拿它注入失败会变成「什么都没跑就成功」，测试假绿。
        result = self.deploy(TEST_FAIL_SERVICE="ldapadmin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image pull failed: ldapadmin", result.stdout)
        self.assertIn("相关服务: ldapadmin", result.stderr)
        self.assertIn("test log tail", result.stderr)
        self.assertTrue(any("logs" in call and call[-2:] == ["--tail=50", "ldapadmin"]
                            for call in self.calls()))
        self.assertNotIn("部署完成", result.stdout)

    def test_health_failure_never_uses_auth_redirect_as_readiness(self):
        for health in ("running starting", "running unhealthy",
                       "running missing-healthcheck", "exited unhealthy"):
            with self.subTest(health=health):
                result = self.deploy(TEST_HEALTH=health)
                self.assertNotEqual(result.returncode, 0)
                # 第一批就是 dnsmasq：它不 healthy 就不该继续
                self.assertIn("dnsmasq", result.stderr)
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

    def test_deprecated_port_and_domain_overrides_are_rejected(self):
        for variable in ("SERVICE_PORT", "SERVICE_DOMAIN"):
            with self.subTest(variable=variable):
                result = self.deploy(**{variable: "8080"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("已废弃", result.stderr)
                self.assertFalse(any("up" in call for call in self.calls()))

    def test_doctor_is_read_only(self):
        # doctor 会对发布端口做真 bind；CI runner 是普通用户，绑不了 80/443，
        # 所以这里让 mock 把发布端口换成 0（内核分配），只保留「只读」这个断言目标。
        result = subprocess.run(
            [sys.executable, "scripts/doctor.py"], cwd=self.root,
            env=dict(self.env, TEST_PUBLISHED_PORTS="0 0"),
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("只读，不启动容器", result.stdout)
        self.assertIn(".env 不存在", result.stdout)
        self.assertFalse((self.root / ".env").exists())
        for call in self.calls():
            self.assertFalse(set(call) & {"up", "run", "start", "pull", "build"})


class AgentDockerAccessTests(unittest.TestCase):
    """agent 容器里的 jenkins(1000) 必须能驱动宿主 docker（2026-11-01 真机验收踩到）。

    上游 ssh-agent 镜像 `PermitRootLogin no`，Jenkins 连进来是 jenkins 用户，
    而 /var/run/docker.sock 是 root:<docker 组> 0660 —— 不补组就 permission denied，
    报错还会伪装成「找不到网络 orgflow」，排查成本极高。

    ★ 关键陷阱：**compose 的 group_add 单独不够**。它只给容器的 PID 1 加附加组，
      而 sshd 给登录会话调 initgroups()、按 /etc/group 重置附加组。于是
      `docker exec -u jenkins ... docker info` 能过、真实 SSH 会话却 permission denied
      —— 拿 docker exec 做端到端检查是假阳性。所以真正的修法在 entrypoint 里
      改 /etc/group，判据也必须走 su（和 sshd 一样调 initgroups）。
    """

    def test_compose_passes_the_socket_gid_to_the_agent(self):
        # 不按服务切块（切块规则一改服务顺序就失效），直接看 socket 挂载点前面
        # 那一段里有没有 group_add —— 两者必须挨在一起，否则就是给别的服务补的组。
        lines = (ROOT / "docker-compose.yml").read_text().splitlines()
        index = next(i for i, line in enumerate(lines)
                     if line.strip() == "- /var/run/docker.sock:/var/run/docker.sock")
        window = "\n".join(lines[max(0, index - 40):index])
        self.assertIn("group_add:", window)
        self.assertIn('"${DOCKER_GID:-0}"', window)
        # entrypoint 要自己改 /etc/group，所以还得把 gid 当环境变量传进去
        self.assertIn("\n      - DOCKER_GID\n", window)

    def test_entrypoint_writes_the_gid_into_etc_group(self):
        # 这是唯一真正生效的修法：group_add 到不了 SSH 会话，改 /etc/group 才能
        # 让 initgroups() 带上这个 gid。
        text = (ROOT / "tools/jenkins-agent/agent-entrypoint.sh").read_text()
        self.assertIn("usermod -aG docker jenkins", text)
        self.assertIn("groupadd -o -g", text)
        self.assertIn("getent group docker", text)

    def test_every_entry_point_detects_the_gid(self):
        # deploy.sh / harness / Makefile 是三条独立的起栈路径，少一条就是
        # 「make deploy 正常、make up 挂」这种最难查的形态。
        for name in ("scripts/deploy.sh", "tests/harness/entrypoint.sh"):
            with self.subTest(file=name):
                text = (ROOT / name).read_text()
                self.assertIn("stat -c %g /var/run/docker.sock", text)
                self.assertIn("export DOCKER_GID", text)
        self.assertIn("DOCKER_GID ?= $(shell stat -c %g /var/run/docker.sock",
                      (ROOT / "Makefile").read_text())

    def test_deploy_verifies_the_agent_can_reach_the_daemon(self):
        # healthy 只证明 sshd 在听，证明不了 docker 能用。必须真跑一次 docker info。
        text = (ROOT / "scripts/deploy.sh").read_text()
        self.assertIn("docker exec of-jenkins-agent su -s /bin/sh -c 'docker info' jenkins", text)
        self.assertIn("DOCKER_GID=${DOCKER_GID:-未设置}", text)

    def test_deploy_never_checks_via_docker_exec_user(self):
        # 反向断言：`docker exec -u jenkins` 会继承 OCI spec 的 AdditionalGids，
        # 即使在真机上 job 全挂也照样通过 —— 用它当判据等于没有判据。
        text = (ROOT / "scripts/deploy.sh").read_text()
        code = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("#")
        )
        self.assertNotIn("docker exec -u jenkins", code)


class AgentHostKeyTests(unittest.TestCase):
    """agent 的 sshd host key 必须跨容器重建稳定（2026-11-01 真机验收踩到）。

    原来用的是 manuallyTrustedKeyVerificationStrategy + requireInitialManualTrust=false，
    注释声称「避免每次重启都要人点信任」——实测是错的：它记的是**第一次见到的 key**，
    而 agent 容器的 /etc/ssh 不持久化，`ssh-keygen -A` 每次重建都换新 key。
    结果是节点离线、三个 pipeline job 全 pending，页面上等一个没人会去点的按钮；
    agent 侧只留一行 `Connection closed ... [preauth]`，完全看不出是 host key。

    正解：host key 做成受管产物（secrets/agent_host_key 挂进容器覆盖
    /etc/ssh/ssh_host_ed25519_key），JCasC 显式声明期望值。四件事缺一不可。
    """

    def test_gen_script_creates_and_reuses_the_host_key(self):
        text = (ROOT / "scripts/gen-agent-key.sh").read_text()
        self.assertIn('HOST_KEY="$KEY_DIR/agent_host_key"', text)
        self.assertIn('ssh-keygen -t ed25519 -N \'\'', text)
        # 幂等：已存在就必须复用。覆盖等于所有 agent 立刻连不上，
        # 而且 Jenkins 里那份 manuallyProvided 的 key 还指着旧的。
        self.assertIn('if [ ! -s "$HOST_KEY" ]', text)

    def test_compose_mounts_the_host_key_over_the_ed25519_slot(self):
        text = (ROOT / "docker-compose.yml").read_text()
        # 必须覆盖 ssh_host_ed25519_key 这个名字：`ssh-keygen -A` 见到已存在就跳过，
        # 换别的文件名等于没固定（-A 还是会生成 ed25519）。
        self.assertIn("./secrets/agent_host_key:/etc/ssh/ssh_host_ed25519_key:ro", text)
        # 挂到 agent 而不是别的服务：紧挨着 socket 挂载点那一小段里出现
        lines = text.splitlines()
        index = next(i for i, line in enumerate(lines)
                     if line.strip() == "- /var/run/docker.sock:/var/run/docker.sock")
        window = "\n".join(lines[index:index + 12])
        self.assertIn("ssh_host_ed25519_key:ro", window)

    def test_jcasc_provides_the_key_instead_of_trusting_first_sight(self):
        text = (ROOT / "config/jenkins.yaml").read_text()
        self.assertIn("manuallyProvidedKeyVerificationStrategy:", text)
        self.assertIn('key: "${JENKINS_AGENT_HOST_KEY}"', text)
        # 反向断言只看**非注释行**：注释里为了说明历史必然会提到旧策略名，
        # 整份文本搜会把「解释为什么改」当成「还没改」。
        code = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("#")
        )
        self.assertNotIn("manuallyTrustedKeyVerificationStrategy", code)
        self.assertNotIn("requireInitialManualTrust", code)

    def test_every_entry_point_exports_the_host_key(self):
        # deploy.sh / harness / Makefile 是三条独立的起栈路径。compose 里是**裸变量**
        # 透传，少导出一处就是空值；而该策略在构造时就 parseKey，
        # 空串会让 JCasC 整份配置应用失败（Jenkins 直接起不来）。
        for name in ("scripts/deploy.sh", "tests/harness/entrypoint.sh"):
            with self.subTest(file=name):
                text = (ROOT / name).read_text()
                self.assertIn("export JENKINS_AGENT_HOST_KEY", text)
                self.assertIn("agent_host_key.pub", text)
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn("JENKINS_AGENT_HOST_KEY ?=", makefile)
        self.assertIn("export JENKINS_AGENT_HOST_KEY", makefile)

    def test_compose_passes_the_key_to_jenkins(self):
        text = (ROOT / "docker-compose.yml").read_text()
        # 不带 `=` 才是「从宿主环境取值」；写成 `- JENKINS_AGENT_HOST_KEY=`
        # 会把空串固定进去，JCasC 拿到空 key 直接启动失败。
        self.assertIn("\n      - JENKINS_AGENT_HOST_KEY\n", text)

    def test_public_key_is_trimmed_to_two_columns(self):
        # .pub 的第三列是注释（jenkins-agent-host@orgflow-devops）。
        # 带着注释去 parseKey 会解析失败，所以三处都必须切成前两列。
        sample = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPwZ+PvlC5u8UlDDrz41OIt3lnNK7a5Zqb6IrVpIa7iw jenkins-agent-host@orgflow-devops\n"
        for name in ("scripts/deploy.sh", "tests/harness/entrypoint.sh"):
            with self.subTest(file=name):
                self.assertIn("""awk 'NR==1{print $1" "$2}'""", (ROOT / name).read_text())
        result = subprocess.run(
            ["sh", "-c", """printf '%s' "$1" | awk 'NR==1{print $1" "$2}'""", "sh", sample],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = result.stdout.strip().split(" ")
        self.assertEqual(fields[0], "ssh-ed25519")
        self.assertEqual(len(fields), 2)


class WinAcceptanceScriptTests(unittest.TestCase):
    """PowerShell 验收脚本在 PS 5.1 上的三个陷阱（2026-11-01 真机）。

    1. HttpClient 的自定义证书回调在**线程池线程**上执行，PS 5.1 会抛
       「此线程中没有可用于运行脚本的运行空间」——报错完全指不到证书上，
       看起来像「根证书没导入」。SslStream 的回调在 AuthenticateAsClient 里
       **同步同线程**调用，ScriptBlock 委托才正常。
    2. dex 的根路径 `/` 本来就是 404（dex 没有根 handler），
       判据必须打 `/dex/healthz`；写成「/ 期望 302」会永远红。
    3. .ps1 必须是 UTF-8 带 BOM + CRLF，否则中文乱码、块解析错乱。
    """

    def setUp(self):
        self.dir = ROOT / "tools/win-acceptance"

    def test_cert_info_comes_from_sslstream_not_httpclient(self):
        text = (self.dir / "Test-OrgflowAcceptance.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("System.Net.Security.SslStream", text)
        self.assertNotIn("System.Net.Http.HttpClient", text)

    def test_dex_is_probed_at_healthz(self):
        text = (self.dir / "Test-OrgflowAcceptance.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("'dex' = '/dex/healthz'", text)
        self.assertIn("'dex'       = @(200)", text)

    def test_scripts_are_utf8_bom_with_crlf(self):
        for path in sorted(self.dir.glob("*.ps1")):
            with self.subTest(file=path.name):
                raw = path.read_bytes()
                self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), "缺 UTF-8 BOM")
                self.assertEqual(raw.count(b"\n") - raw.count(b"\r\n"), 0, "存在裸 LF")


class HostsSnippetTests(unittest.TestCase):
    """gen-hosts.sh 的输出会直接写进 /etc/hosts，格式错了排查成本极高。"""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ("scripts/gen-hosts.sh", "config/routes.yaml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def snippet(self, *args, **env):
        return subprocess.run(
            ["bash", "scripts/gen-hosts.sh", *args], cwd=self.root,
            env=dict(os.environ, **env), capture_output=True, text=True, timeout=20,
        )

    def test_every_subdomain_stays_on_its_own_field(self):
        result = self.snippet("10.0.0.5")
        self.assertEqual(result.returncode, 0, result.stderr)
        line = next(l for l in result.stdout.splitlines() if l.startswith("10.0.0.5 "))
        # 回归点：曾用 tr -d '[:space:]' 处理多行，多个域名被粘成一行
        self.assertEqual(line.split()[1:], [
            "jenkins.org-devops.com", "nexus.org-devops.com",
            "ldapadmin.org-devops.com", "dex.org-devops.com",
            "auth.org-devops.com", "home.org-devops.com",
        ])

    def test_domain_override_changes_the_suffix(self):
        result = self.snippet("10.0.0.6", GATEWAY_DOMAIN="example.test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("jenkins.example.test", result.stdout)
        self.assertNotIn("org-devops.com", result.stdout)


if __name__ == "__main__":
    unittest.main()
