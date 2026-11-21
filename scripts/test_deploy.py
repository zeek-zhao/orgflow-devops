import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import config as cfgmod  # noqa: E402  (配置读取的唯一入口)


ROOT = Path(__file__).resolve().parents[1]

# 新部署链（M0 重构）：50-deploy 编排，其余是被它调用的步骤脚本。
DEPLOY_DEPENDENCIES = (
    "scripts/50-deploy.sh",
    "scripts/10-render-config.sh",
    "scripts/12-render-dex.sh",
    "scripts/20-gen-ca.sh",
    "scripts/30-up-serial.sh",
    "scripts/40-gen-agent-key.sh",
    "scripts/60-verify-endpoints.sh",
    "scripts/lib/config.py",
    "scripts/lib/runtime.sh",
    # 10-render-config.sh 的内联 python 会 `import rendered_values`（引号转义规则
    # 的单一真源），沙箱里少了它 20 条用例直接 ModuleNotFoundError。
    "scripts/lib/rendered_values.py",
    "scripts/16-doctor.py",
    "config/orgflow.yml",
    "config/services.yml",
    "services/router/render.py",
    "services/auth/dex/config.yaml.tmpl",
    "config/routes.yaml",
)

# 串行启动顺序的真源是 config/services.yml 的 start_order；这里抄一份是为了
# 「改了顺序却没改测试」也红（同步条款）。当前口径见 docs/engineering/使用说明.md。
UP_ORDER = ["dnsmasq", "ldap", "ldapadmin", "dex", "oauth2-proxy", "router",
            "caddy", "homepage", "docs", "jenkins", "jenkins-agent"]


def write_config(root: Path, *, https_port: int | None = None, domain: str | None = None,
                 ldap_password: str | None = None,
                 oauth2_cookie_secret: str | None = None) -> None:
    """改写沙箱里的 config/orgflow.yml —— 新栈唯一的配置入口（不再有 .env）。"""
    path = root / "config/orgflow.yml"
    text = path.read_text(encoding="utf-8")
    if https_port is not None:
        text = re.sub(r"(?m)^(\s*https_port:\s*)\d+", rf"\g<1>{https_port}", text, count=1)
    if domain is not None:
        text = re.sub(r"(?m)^(\s*domain:\s*)\S+", rf"\g<1>{domain}", text, count=1)
    if ldap_password is not None:
        text = re.sub(r"(?m)^(\s*password:\s*)\S+", rf'\g<1>"{ldap_password}"', text, count=1)
    if oauth2_cookie_secret is not None:
        text = re.sub(r"(?m)^(\s*cookie_secret:\s*).*$",
                      lambda m: f'{m.group(1)}"{oauth2_cookie_secret}"', text, count=1)
    path.write_text(text, encoding="utf-8")


# 沙箱里的 agent 密钥对：orgflow_export_runtime_env 要求 host key 存在，
# 缺了整条链第一步就 fail（真机由 40-gen-agent-key.sh 生成）。
FIXTURE_PRIVATE_KEY = """-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB6ff9J1goWOWl0YdQOVbFt6NLmxuobMlf/R6baBWuGMwAAAJDT2bw309m8
NwAAAAtzc2gtZWQyNTUxOQAAACB6ff9J1goWOWl0YdQOVbFt6NLmxuobMlf/R6baBWuGMw
AAAECSCd1yUG6jvvh5/atJ8Mh9E0i0E98ew57sMnS9SqgTvnp9/0nWChY5aXRh1A5VsW3o
0ubG6hsyV/9HptoFa4YzAAAADGZpeHR1cmVAdGVzdAE=
-----END OPENSSH PRIVATE KEY-----
"""
FIXTURE_HOST_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHp9/0nWChY5aXRh1A5VsW3o0ubG6hsyV/9HptoFa4Yz"


def plant_secrets(root: Path) -> None:
    secrets = root / "secrets"
    secrets.mkdir(parents=True, exist_ok=True)
    (secrets / "agent_ssh_key").write_text(FIXTURE_PRIVATE_KEY)
    (secrets / "agent_host_key.pub").write_text(FIXTURE_HOST_KEY + "\n")


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in DEPLOY_DEPENDENCIES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        plant_secrets(self.root)
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
                        DEPLOY_HEALTH_TIMEOUT="1", DEPLOY_POLL_INTERVAL="1",
                        ORGROFLOW_POLL_INTERVAL="0")
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
    # 域名路由后自检 URL 是 https://auth.<domain>/ping、https://jenkins.<domain>/login、
    # https://jenkins.<domain>/、https://home.<domain>/ —— 一保一护一公开。
    # ★ 2026-11-11 起 jenkins 走「自带登录」（#86 摘网关 auth）：
    #   根路径匿名被 Jenkins 自己拒 = 403，登录页 = 200。替身必须照这个模型，
    #   否则测的是「旧架构下的 deploy.sh」，真机上照样红。
    url = args[-1]
    host_path = url.split("://", 1)[-1]
    forced = os.environ.get("TEST_ALL_STATUS")
    if forced:
        print(forced)
    elif host_path.endswith("/ping"):
        print(os.environ.get("TEST_PING", "200"))
    elif host_path.endswith("/login"):
        print("200")
    elif host_path.startswith("jenkins."):
        print("403")
    elif host_path.startswith("nexus."):
        print(os.environ.get("TEST_NEXUS_STATUS", "200"))
    elif host_path.startswith(("home.", "ldapadmin.")):
        print("200")
    elif host_path.startswith("docs."):
        print("302")
    elif host_path.startswith("127.0.0.1") or host_path.startswith("localhost"):
        print(os.environ.get("TEST_HOST_PORT_STATUS", "302"))
    elif host_path.endswith("/dex/healthz"):
        print("200")
    elif "docs." in url or "auth." in url:
        print("302")
    else:
        print("302")
elif args[0] == "inspect":
    calls = [json.loads(line) for line in Path("calls.jsonl").read_text().splitlines()]
    if os.environ.get("TEST_MISSING_CONTAINER"):
        sys.exit(1)
    if os.environ.get("TEST_FINAL_FAILURE") and len(
            [call for call in calls if "up" in call]) >= 2:
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
elif "up" in args and (args[-1] == os.environ.get("TEST_FAIL_SERVICE")
                        or (os.environ.get("TEST_PULL_FAIL")
                            and args[-1] == os.environ["TEST_PULL_FAIL"])):
    print("image pull failed: " + args[-1], file=sys.stderr)
    sys.exit(23)
elif "up" in args:
    sys.exit(0)
elif "logs" in args:
    print("test log tail " + os.environ.get("TEST_LOG_SECRET", ""))
elif args[0] == "ps" and "-aq" in args:
    print(os.environ.get("TEST_CONTAINER_ID", "cid-of"))
elif args[0] == "ps" and "-aq" in args:
    # orgflow_wait_healthy 先按容器名取 id；取不到就判「容器不存在」
    if os.environ.get("TEST_MISSING_CONTAINER"):
        sys.exit(0)
    print(os.environ.get("TEST_CONTAINER_ID", "cid-of"))
elif "ps" in args:
    sys.exit(0)
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

    def write_config(self, **overrides):
        write_config(self.root, **overrides)

    def deploy(self, *args, **env):
        return subprocess.run(
            ["bash", "scripts/50-deploy.sh", *args], cwd=self.root, env=dict(self.env, **env),
            # 沙箱里每个 mock 调用都要 fork 一次 python3，11 个服务串行下来 30 秒不够；
            # 真实耗时不是被测对象，被测的是「顺序 / 失败即停 / 文案」。
            capture_output=True, text=True, timeout=180,
        )

    def calls(self):
        # 前置校验（如废弃变量、Compose 解析失败）会直接 exit，一条外部命令都没调过，
        # 日志文件根本不存在——这不是错误，就是「零调用」。
        log = self.root / "calls.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    def test_gateway_port_comes_from_config_not_hardcoded(self):
        """网关端口只能来自 config/orgflow.yml：改配置 → runtime.env 跟着变 → 入口 URL 带端口。

        为什么不再有「.env 原样保留」这条：配置的唯一真源改成 config/orgflow.yml 之后，
        渲染产物 out/runtime.env 每次部署都重写（那是产物，不是输入），
        再断言"它不被改动"就等于把产物当配置，正是要消灭的坑。
        """
        write_config(self.root, https_port=18443)
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = dict(
            line.split("=", 1)
            for line in (self.root / "out/runtime.env").read_text().splitlines()
            if "=" in line and not line.startswith("#")
        )
        self.assertEqual(rendered["GATEWAY_HTTPS_PORT"], "18443")
        self.assertIn("HTTPS 18443", result.stdout)
        # 非 443 时给人看的入口 URL 必须带端口，否则复制出去打不开
        self.assertIn("jenkins/login", result.stdout)

    def test_self_check_url_carries_the_same_port_as_resolve(self):
        """--resolve 是按 host:port 精确匹配的，URL 不带端口就退回真实 DNS。

        只断言输出文案不够：默认 443 时 URL 的隐式端口恰好等于映射端口，
        文案看着完全正确，而真正传给 curl 的地址可能是错的。所以这里断言
        **curl 的实际参数**——resolve 的端口和 URL 的端口必须逐字一致。
        """
        write_config(self.root, https_port=18443)
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
        # 域名层每个自检项都必须走 gw()（带 --resolve + 端口）。这里只要求
        # 「至少 7 项都被检查过」而不写死数字：加自检项不该改这条用例，
        # 但少检查一项、或某一项绕过 gw() 直接 curl，必须红。
        self.assertGreaterEqual(checked, 7, f"只检查了 {checked} 项")

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
        result = self.deploy("--service", "router", USE_GHCR="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        ups = [call for call in self.calls() if call[0] == "docker" and "up" in call]
        self.assertEqual(len(ups), 1, f"应只 up 一次: {ups}")
        self.assertIn("--no-build", ups[0], f"GHCR 下 --service 缺 --no-build: {ups[0]}")

    def test_gateway_domain_override_flows_into_caddyfile_and_dex(self):
        write_config(self.root, domain="example.test")
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        caddyfile = (self.root / "out/Caddyfile").read_text()
        self.assertIn("https://jenkins.example.test {", caddyfile)
        self.assertIn("https://docs.example.test/oauth2/start", caddyfile)
        self.assertNotIn("org-devops.com", caddyfile)
        dex = (self.root / "out/dex/config.yaml").read_text()
        self.assertIn("issuer: https://dex.example.test/dex", dex)
        self.assertIn("https://auth.example.test/oauth2/callback", dex)
        self.assertNotIn("__DEX_ISSUER__", dex)
        self.assertIn("jenkins/login = 200", result.stdout)
        self.assertIn("jenkins/ = 403", result.stdout)

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
        # 文案随 30-up-serial 改：拉取/构建失败在 compose 层就是 up 失败，
        # 关键是必须点名**是哪个服务**、并且带上 compose 的原始退出码。
        self.assertIn("ldapadmin 启动失败（拉取/构建阶段）", result.stderr)
        self.assertIn("失败诊断：ldapadmin", result.stderr)
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
        write_config(self.root, ldap_password=secret)
        result = self.deploy(TEST_FAIL_SERVICE="ldap", TEST_LOG_SECRET=secret)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[REDACTED]", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_wrong_endpoint_status_is_failure(self):
        result = self.deploy(TEST_PING="302")
        self.assertNotEqual(result.returncode, 0)
        # 逐项行：`✗ [域名层] auth/ping = 302（期望 200）`
        self.assertIn("auth/ping = 302", result.stderr)
        self.assertIn("（期望 200）", result.stderr)
        self.assertNotIn("部署完成", result.stdout)

    def test_final_barrier_detects_earlier_service_failure(self):
        result = self.deploy(TEST_FINAL_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ldap: running unhealthy", result.stderr)
        self.assertFalse(any(call[0] == "curl" for call in self.calls()))

    def test_config_error_does_not_expose_secret(self):
        """配置错误必须报**字段名**，绝不回显值：值里往往就是口令本身。

        配置源已改为 config/orgflow.yml（不再走 .env），所以这里的做法是把
        oauth2.cookie_secret 写坏（太短会触发校验），口令值本身必须不出现在任何输出里。
        """
        secret = "malformed-secret-123"
        write_config(self.root, oauth2_cookie_secret=secret)
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cookie_secret", result.stderr)
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
        # doctor 读 .env 或渲染产物来算 compose config，沙箱里先渲染一次。
        self.assertEqual(self.deploy().returncode, 0, "前置部署应成功，否则 doctor 无产物可读")
        prepared = len(self.calls())   # 前置部署产生的调用到此为止
        result = subprocess.run(
            [sys.executable, "scripts/16-doctor.py"], cwd=self.root,
            # doctor 需要 .env 或渲染产物才能算 compose config；沙箱里指到渲染产物，仍只读。
            env=dict(self.env, TEST_PUBLISHED_PORTS="0 0", ENV_FILE="out/runtime.env"),
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("只读，不启动容器", result.stdout)
        # doctor 只说「哪一个 env 文件存在」，不回显内容；配置真源不再是 .env
        self.assertIn("out/runtime.env 已存在", result.stdout)
        self.assertNotIn("LDAP_ADMIN_PASSWORD", result.stdout)
        # 只看 doctor 自己产生的调用：前置 deploy 会 up，那是沙箱准备工作，不是 doctor 的行为
        for call in self.calls()[prepared:]:
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
        # 2026-11 拆分后 socket 挂在服务自己的片段里（tools/jenkins-agent 是别名）
        fragment = ROOT / "services/jenkins-agent/compose.yml"
        lines = fragment.read_text().splitlines()
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
        for name in ("scripts/lib/runtime.sh", "tests/harness/entrypoint.sh"):
            with self.subTest(file=name):
                text = (ROOT / name).read_text()
                self.assertIn("stat -c %g /var/run/docker.sock", text)
                self.assertIn("export DOCKER_GID", text)
        self.assertIn("DOCKER_GID ?= $(shell stat -c %g /var/run/docker.sock",
                      (ROOT / "Makefile").read_text())

    def test_deploy_verifies_the_agent_can_reach_the_daemon(self):
        # healthy 只证明 sshd 在听，证明不了 docker 能用。必须真跑一次 docker info。
        text = (ROOT / "scripts/50-deploy.sh").read_text()
        self.assertIn("su -s /bin/sh -c 'docker info' jenkins", text)
        self.assertIn("DOCKER_GID=${DOCKER_GID:-未设置}", text)

    def test_deploy_never_checks_via_docker_exec_user(self):
        # 反向断言：`docker exec -u jenkins` 会继承 OCI spec 的 AdditionalGids，
        # 即使在真机上 job 全挂也照样通过 —— 用它当判据等于没有判据。
        text = (ROOT / "scripts/50-deploy.sh").read_text()
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
        text = (ROOT / "scripts/40-gen-agent-key.sh").read_text()
        self.assertIn('HOST_KEY="$KEY_DIR/agent_host_key"', text)
        self.assertIn('ssh-keygen -t ed25519 -N \'\'', text)
        # 幂等：已存在就必须复用。覆盖等于所有 agent 立刻连不上，
        # 而且 Jenkins 里那份 manuallyProvided 的 key 还指着旧的。
        self.assertIn('if [ ! -s "$HOST_KEY" ]', text)

    def test_compose_mounts_the_host_key_over_the_ed25519_slot(self):
        # 2026-11 拆分：agent 的挂载点在自己的片段里，根 compose 只剩 include
        text = (ROOT / "services/jenkins-agent/compose.yml").read_text()
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
        for name in ("scripts/lib/runtime.sh", "tests/harness/entrypoint.sh"):
            with self.subTest(file=name):
                text = (ROOT / name).read_text()
                self.assertIn("export JENKINS_AGENT_HOST_KEY", text)
                self.assertIn("agent_host_key.pub", text)
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn("JENKINS_AGENT_HOST_KEY ?=", makefile)
        self.assertIn("export JENKINS_AGENT_HOST_KEY", makefile)

    def test_compose_passes_the_key_to_jenkins(self):
        # 拆分后这条断言读的是 jenkins 自己的片段
        text = (ROOT / "services/jenkins/compose.yml").read_text()
        # 不带 `=` 才是「从宿主环境取值」；写成 `- JENKINS_AGENT_HOST_KEY=`
        # 会把空串固定进去，JCasC 拿到空 key 直接启动失败。
        self.assertIn("\n      - JENKINS_AGENT_HOST_KEY\n", text)

    def test_public_key_is_trimmed_to_two_columns(self):
        # .pub 的第三列是注释（jenkins-agent-host@orgflow-devops）。
        # 带着注释去 parseKey 会解析失败，所以三处都必须切成前两列。
        sample = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPwZ+PvlC5u8UlDDrz41OIt3lnNK7a5Zqb6IrVpIa7iw jenkins-agent-host@orgflow-devops\n"
        for name in ("scripts/lib/runtime.sh", "tests/harness/entrypoint.sh"):
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
        # 用正则而非精确字面量：#117 把 $ProbePaths 从单行改成多行对齐的 hashtable，
        # 写死空格数会把「格式调整」误报成「判据丢了」。判据本身没有放宽 —— 键、
        # 路径、以及 $ProbePaths 真的被 Test-Site 用上，缺任意一项都会红。
        self.assertRegex(text, r"\$ProbePaths\s*=\s*@\{")
        self.assertRegex(text, r"'dex'\s*=\s*'/dex/healthz'")
        self.assertRegex(text, r"'docker'\s*=\s*'/v2/'")
        self.assertRegex(text, r"'pypi'\s*=\s*'/repository/pypi-hosted/simple/'")
        self.assertRegex(text, r"\$ProbePaths\.ContainsKey")
        self.assertRegex(text, r"'dex'\s*=\s*@\(200\)")

    def test_windows_hosts_contract_includes_repo_sites(self):
        """#117：Windows hosts 契约 6 -> 8，且打印的条数不能再写死。"""
        text = (self.dir / "Set-OrgflowHosts.ps1").read_text(encoding="utf-8-sig")
        m = re.search(r"\$Subdomains\s*=\s*@\(([^)]*)\)", text)
        self.assertIsNotNone(m, "没找到 $Subdomains 契约数组")
        subs = re.findall(r"'([A-Za-z0-9._-]+)'", m.group(1))
        self.assertEqual(len(subs), 8)
        self.assertIn("docker", subs)
        self.assertIn("pypi", subs)
        # #134：输出条数由数组推导，不能留一个手写的 6
        self.assertRegex(text, r"\$Subdomains\.Count")
        self.assertNotIn("已写入 6 条", text)

    def test_scripts_are_utf8_bom_with_crlf(self):
        for path in sorted(self.dir.glob("*.ps1")):
            with self.subTest(file=path.name):
                raw = path.read_bytes()
                self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), "缺 UTF-8 BOM")
                self.assertEqual(raw.count(b"\n") - raw.count(b"\r\n"), 0, "存在裸 LF")


class JenkinsLdapRealmTests(unittest.TestCase):
    """#87:LDAP 安全域静态口径——referral 必须 ignore(follow 有凭据外泄风险)。"""

    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]
        self.yaml = (self.root / "config/jenkins.yaml").read_text(encoding="utf-8")

    def test_ldap_realm_present(self):
        self.assertGreaterEqual(self.yaml.count("ldap:"), 1)

    def test_logged_in_users_can_do_anything_gone(self):
        self.assertNotIn("loggedInUsersCanDoAnything", self.yaml)

    def test_referral_is_ignore(self):
        # environmentProperties 形状:name/value 两行;follow 即红(#87 反证口径)
        m = re.search(r"name: java\.naming\.referral\s+value: (\w+)", self.yaml)
        self.assertIsNotNone(m, "缺少 java.naming.referral 环境属性")
        self.assertEqual(m.group(1), "ignore")


class HostsSnippetTests(unittest.TestCase):
    """gen-hosts.sh 的输出会直接写进 /etc/hosts，格式错了排查成本极高。"""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ("scripts/22-gen-hosts.sh", "config/routes.yaml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def snippet(self, *args, **env):
        return subprocess.run(
            ["bash", "scripts/22-gen-hosts.sh", *args], cwd=self.root,
            env=dict(os.environ, **env), capture_output=True, text=True, timeout=20,
        )

    def test_every_subdomain_stays_on_its_own_field(self):
        result = self.snippet("10.0.0.5")
        self.assertEqual(result.returncode, 0, result.stderr)
        line = next(l for l in result.stdout.splitlines() if l.startswith("10.0.0.5 "))
        # 回归点：曾用 tr -d '[:space:]' 处理多行，多个域名被粘成一行。
        # 期望值从 routes.yaml 推导而不是写死清单：#117 加了 docker/pypi 之后，
        # 写死 8 条让本用例变红，那是断言过期而不是脚本坏了。判据没放宽 ——
        # 仍逐字段精确比对，任一域名缺失、多出或被粘成一行照样红。
        routes = (self.root / "config/routes.yaml").read_text(encoding="utf-8")
        subs = re.findall(
            r"^\s*subdomain:\s*['\"]?([A-Za-z0-9._-]+)['\"]?\s*$",
            routes, re.MULTILINE,
        )
        self.assertGreater(len(subs), 0, "routes.yaml 没解析出任何 subdomain")
        expected = [f"{s}.org-devops.com" for s in subs]
        # #117 的两个仓库站点必须真的进 hosts，否则两条新路由在客户端解析不到
        self.assertIn("docker.org-devops.com", expected)
        self.assertIn("pypi.org-devops.com", expected)
        self.assertEqual(line.split()[1:], expected)

    def test_domain_override_changes_the_suffix(self):
        result = self.snippet("10.0.0.6", GATEWAY_DOMAIN="example.test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("jenkins.example.test", result.stdout)
        self.assertNotIn("org-devops.com", result.stdout)


class ArchIpCheckTests(unittest.TestCase):
    """固定 IP 表的一致性检查必须覆盖**所有**写了这张表的文档。

    2026-11-01 踩到：脚本只核对 `docs/network/arch.md`，于是 `docs/会话交接.md`
    里的同一张表漏了 `jenkins-agent` 一整行，没有任何东西会报警 —— 而交接文档
    是接手人**最先读**的那份，它错了比 arch.md 错了更贵。
    """

    def test_checks_every_document_that_has_the_table(self):
        text = (ROOT / "scripts/check-arch-ips.sh").read_text()
        self.assertIn("DOCS=(", text)
        self.assertIn("docs/network/arch.md", text)
        self.assertIn("docs/会话交接.md", text)
        # 反向断言：不能再退回单文档变量，那等于把这次修的洞重新打开
        self.assertNotIn('DOC="$ROOT/docs/network/arch.md"', text)

    def test_a_document_without_rows_is_an_error(self):
        # 静默通过比报错危险：表格格式一改，检查就失效且没人知道
        self.assertIn("没解析出任何 IP 行", (ROOT / "scripts/check-arch-ips.sh").read_text())

    def test_documents_must_agree_with_each_other(self):
        # 两份文档写同一个服务不同 IP 时必须报错，而不是「后写的覆盖先写的」
        self.assertIn("在文档之间不一致", (ROOT / "scripts/check-arch-ips.sh").read_text())


class InitScriptTests(unittest.TestCase):
    """make init 的回归门禁（#140）。

    真机踩到：docker ps 的 --format 里写 .Health 会报
    `can't evaluate field Health in type *formatter.ContainerContext`，
    明明 healthy 的 of-nexus 被判成「尚未运行」。.Health 是
    docker compose ps 的字段；docker ps 必须走 docker inspect 读真实状态。
    """

    def _text(self):
        return (ROOT / "scripts/51-init.sh").read_text()

    def test_nexus_health_uses_docker_inspect(self):
        text = self._text()
        self.assertIn("docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}", text)
        self.assertIn('"$nexus_health" = "healthy"', text)

    def test_docker_ps_must_not_use_health_field(self):
        # 反向断言：改回 docker ps .Health 就是把这次修的假红重新打开
        text = self._text()
        self.assertNotIn("docker ps --format '{{.Names}} {{.Health}}'", text)
        for line in text.splitlines():
            if line.lstrip().startswith("#"):
                continue  # 注释里说明这个坑的句子不算命令
            if "docker ps " in line and "--format" in line:
                self.assertNotIn(".Health", line, line)

    def test_entry_list_never_prints_a_password_value(self):
        text = self._text()
        self.assertIn("脚本不打印任何口令", text)
        # 口令位置这一行只允许展开 $ENV_FILE（文件名），不得展开任何 .env 键
        for line in text.splitlines():
            if line.lstrip().startswith("printf") and "口令位置" in line:
                self.assertIn("$ENV_FILE", line)
                self.assertNotIn("${", line)



class RenderConfigTests(unittest.TestCase):
    """scripts/10-render-config.sh：config/orgflow.yml → out/runtime.env。

    这一层是"配置唯一真源"落地的关键：渲染产物必须是 0600、必须每次重算、
    必须不含任何从 .env 继承来的残留，否则又回到"人手改产物"的老路。
    """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("scripts/10-render-config.sh", "scripts/12-render-dex.sh",
                     "scripts/lib/config.py", "scripts/lib/runtime.sh",
                     "scripts/lib/rendered_values.py",
                     "config/orgflow.yml", "config/services.yml",
                     "config/routes.yaml", "services/router/render.py",
                     "services/auth/dex/config.yaml.tmpl"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def render(self, **env):
        base = {key: value for key, value in os.environ.items()
                if key not in ("RUNTIME_ENV", "GATEWAY_DOMAIN", "GATEWAY_HTTP_PORT",
                               "GATEWAY_HTTPS_PORT", "ENV_FILE", "ENV_NAME")}
        base["PATH"] = "/usr/bin:/bin:/usr/local/bin"
        return subprocess.run(
            ["bash", "scripts/10-render-config.sh"], cwd=self.root,
            env=dict(base, **env), capture_output=True, text=True, timeout=60,
        )

    def values(self):
        text = (self.root / "out/runtime.env").read_text()
        return dict(line.split("=", 1) for line in text.splitlines()
                    if "=" in line and not line.startswith("#"))

    def test_runtime_env_is_owner_only(self):
        """口令在里面，权限必须是 0600 —— 0644 等于把口令给了所有本地账号。"""
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        mode = (self.root / "out/runtime.env").stat().st_mode & 0o777
        self.assertEqual(oct(mode), "0o600")

    def test_render_is_idempotent_and_rewrites_stale_values(self):
        """手改过产物也要被下一次渲染覆盖：产物不是输入。"""
        self.assertEqual(self.render().returncode, 0)
        path = self.root / "out/runtime.env"
        path.write_text(path.read_text() + "STALE_KEY=1\n")
        self.assertEqual(self.render().returncode, 0)
        self.assertNotIn("STALE_KEY", path.read_text())

    def test_config_error_names_the_field_without_leaking_values(self):
        # 报错必须点名**字段**（能照着改），但不能把值打出来——值里常常就是口令。
        config = self.root / "config/orgflow.yml"
        config.write_text(
            re.sub(r"(?m)^(\s*base_dn:\s*).*$", r"\g<1>not-a-dn",
                   config.read_text(encoding="utf-8"), count=1),
            encoding="utf-8")
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("base_dn", result.stderr)

    def test_caddyfile_carries_the_site_and_the_ca(self):
        self.assertEqual(self.render().returncode, 0)
        caddyfile = (self.root / "out/Caddyfile").read_text()
        self.assertIn("tls /certs/orgflow-ca.crt /certs/orgflow-ca.key", caddyfile)
        self.assertNotIn("local_certs", caddyfile)


class UpSerialTests(unittest.TestCase):
    """scripts/30-up-serial.sh：按 config/services.yml 的 start_order 逐个起。

    串行的意义是"前一个健康了才起下一个"：并行 up 会让后者拿着未就绪的
    LDAP/DNS 起来，表现为随机 401 与随机的 DNS 解析失败——问过的所有人都
    以为是密码问题。
    """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("scripts/30-up-serial.sh", "scripts/lib/config.py",
                     "scripts/lib/runtime.sh", "config/orgflow.yml",
                     "config/services.yml", "docker-compose.yml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        (self.root / "out").mkdir()
        (self.root / "out/runtime.env").write_text("GATEWAY_DOMAIN=org-devops.com\n")
        plant_secrets(self.root)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open("calls.jsonl", "a") as log:
    log.write(json.dumps([Path(sys.argv[0]).name, *args]) + "\\n")
if args[0] == "ps" and "-aq" in args:
    # orgflow_wait_healthy 先按容器名取 id，取不到就判「容器不存在」
    print(os.environ.get("TEST_CONTAINER_ID", "cid-of"))
elif args[0] == "inspect":
    state = os.environ.get("TEST_STATE", "running healthy")
    if state not in ("running healthy", "running no-healthcheck"):
        sys.exit(1)
    print(state)
elif os.environ.get("TEST_FAIL_SERVICE") and args[-1] == os.environ["TEST_FAIL_SERVICE"]:
    print("pull access denied", file=sys.stderr)
    sys.exit(1)
"""
        path = self.bin / "docker"
        path.write_text(mock)
        path.chmod(0o755)

    def up(self, *args, **env):
        base = {key: value for key, value in os.environ.items()
                if key not in ("RUNTIME_ENV", "USE_GHCR", "KEEP")}
        base["PATH"] = f"{self.bin}:/usr/bin:/bin"
        base["ORGROFLOW_POLL_INTERVAL"] = "0"
        base["HEALTH_TIMEOUT"] = "2"
        return subprocess.run(
            ["bash", "scripts/30-up-serial.sh", *args], cwd=self.root,
            env=dict(base, **env), capture_output=True, text=True, timeout=60,
        )

    def calls(self):
        log = self.root / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_start_order_comes_from_the_config_file(self):
        """顺序的唯一真源是 config/services.yml：脚本自己不再硬编码一份。"""
        text = (ROOT / "scripts/30-up-serial.sh").read_text()
        self.assertIn("orgflow_start_order", text)
        self.assertNotIn("homepage docs jenkins jenkins-agent", text)
        # 与配置里的 start_order 对照（配置改了而这里没改，就是两条真源）
        registry = cfgmod.load_services()
        self.assertEqual(cfgmod.start_order(registry),
                         ["dnsmasq", "ldap", "ldapadmin", "dex", "oauth2-proxy",
                          "router", "caddy", "homepage", "docs", "jenkins",
                          "jenkins-agent"])

    def test_each_service_waits_for_the_previous_one(self):
        """串行的语义：前一个 unhealthy 就必须停，后面的一个都不能 up。"""
        # dnsmasq 是 list 的第一个：让它 unhealthy，后面一个都不许 up
        result = self.up(TEST_FAIL_SERVICE="dnsmasq")
        self.assertNotEqual(result.returncode, 0)
        ups = [call[-1] for call in self.calls() if "up" in call]
        self.assertEqual(ups, ["dnsmasq"], f"失败后还在继续起服务：{ups}")

    def test_each_service_is_awaited_before_the_next(self):
        """up 之后必须紧跟一次 inspect 等待；只 up 不等的脚本等于并行。"""
        self.assertEqual(self.up().returncode, 0)
        kinds = [call[0] if call[0] == "docker" else call[0] for call in self.calls()]
        ups = [i for i, call in enumerate(self.calls()) if "up" in call]
        inspects = [i for i, call in enumerate(self.calls()) if "inspect" in call]
        self.assertEqual(len(inspects), len(ups), f"{kinds}")

    def test_up_uses_no_deps_so_order_is_the_contract(self):
        self.assertEqual(self.up().returncode, 0)
        for call in self.calls():
            if "up" in call:
                self.assertIn("--no-deps", call, call)

    def test_ghcr_mode_adds_the_pin_file_and_never_builds(self):
        self.assertEqual(self.up(USE_GHCR="1").returncode, 0)
        for call in self.calls():
            if "up" in call:
                self.assertIn("docker-compose.ghcr.yml", " ".join(call))
                self.assertIn("--no-build", call)

    def test_single_service_argument_skips_the_order(self):
        self.assertEqual(self.up("homepage").returncode, 0)
        ups = [call[-1] for call in self.calls() if "up" in call]
        self.assertEqual(ups, ["homepage"])



class VerifyEndpointsTests(unittest.TestCase):
    """scripts/60-verify-endpoints.sh：三层递进自检（容器内 → 宿主机 → 域名）。

    单独拿出来测，是因为这三层的失败信息必须能区分：容器没起、端口没映射、
    还是域名/证书/路由错了。混在一起报「200 才算过」，排查时等于没说。
    """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("scripts/60-verify-endpoints.sh", "scripts/lib/config.py",
                     "scripts/lib/runtime.sh", "config/orgflow.yml",
                     "config/services.yml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        (self.root / "out").mkdir()
        (self.root / "out/runtime.env").write_text("GATEWAY_DOMAIN=org-devops.com\n")
        plant_secrets(self.root)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
with open("calls.jsonl", "a") as log:
    log.write(json.dumps([tool, *args]) + "\\n")
if tool == "docker":
    if args and args[0] == "ps" and "-aq" in args:
        print(os.environ.get("TEST_CONTAINER_ID", "cid-of"))
    elif args and args[0] == "inspect":
        print(os.environ.get("TEST_STATE", "running healthy"))
    sys.exit(0)
url = args[-1]
status = os.environ.get("TEST_ALL_STATUS")
host_path = url.split("://", 1)[-1]
if status:
    print(status)
elif host_path.endswith("/ping"):
    print("200")
elif host_path.endswith("/login") or host_path.endswith("/dex/healthz"):
    print("200")
elif host_path.startswith("nexus."):
    print(os.environ.get("TEST_NEXUS_STATUS", "502"))
elif host_path.startswith(("home.", "ldapadmin.")):
    print("200")
elif host_path.startswith(("docs.", "auth.")):
    print("302")
elif host_path.startswith("127.0.0.1") or host_path.startswith("localhost"):
    print(os.environ.get("TEST_HOST_PORT_STATUS", "302"))
else:
    print("403")
"""
        for name in ("docker", "curl"):
            path = self.bin / name
            path.write_text(mock)
            path.chmod(0o755)

    def verify(self, **env):
        base = {key: value for key, value in os.environ.items()
                if key not in ("RUNTIME_ENV", "EXPECT_NEXUS")}
        base["PATH"] = f"{self.bin}:/usr/bin:/bin"
        return subprocess.run(
            ["bash", "scripts/60-verify-endpoints.sh"], cwd=self.root,
            env=dict(base, **env), capture_output=True, text=True, timeout=60,
        )

    def calls(self):
        log = self.root / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_three_layers_are_reported_separately(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for layer in ("第 1 层：容器内自检", "第 2 层：宿主机端口", "第 3 层：域名层"):
            self.assertIn(layer, result.stdout)

    def test_container_layer_reads_health_not_just_running(self):
        result = self.verify(TEST_STATE="running unhealthy")
        self.assertNotEqual(result.returncode, 0, "unhealthy 被判成通过")

    def test_host_layer_checks_the_published_port(self):
        self.assertEqual(self.verify().returncode, 0)
        hosts = [call for call in self.calls()
                 if call[0] == "curl" and "127.0.0.1" in " ".join(call)]
        self.assertTrue(hosts, "宿主机层一条 curl 都没发")

    def test_domain_layer_resolve_carries_the_port(self):
        self.assertEqual(self.verify().returncode, 0)
        resolves = [call[call.index("--resolve") + 1] for call in self.calls()
                    if call[0] == "curl" and "--resolve" in call]
        self.assertTrue(resolves)
        for value in resolves:
            self.assertRegex(value, r"^[^:]+:\d+:", value)

    def test_wrong_status_is_a_failure_not_a_pass(self):
        result = self.verify(TEST_ALL_STATUS="500")
        self.assertNotEqual(result.returncode, 0, "500 被判成通过")

    def test_nexus_gap_is_reported_as_issue_not_as_green(self):
        """Nexus 不在 compose 里（#46）：502 只能是"已知缺口"，不能算通过。

        200 时说明 job 已经把 nexus 部署好了，脚本要明说「已由 job 部署」；
        两种情况的共同要求是：nexus 这一行必须带说明，不能和其他服务混成一句绿。
        """
        gap = self.verify(TEST_NEXUS_STATUS="502")
        self.assertIn("#46", gap.stdout)
        ready = self.verify(TEST_NEXUS_STATUS="200")
        self.assertIn("已由 job 部署", ready.stdout)

if __name__ == "__main__":
    unittest.main()
