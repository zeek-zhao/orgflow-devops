#!/usr/bin/env python3
"""配置单一源的结构与派生一致性门禁（`make test` 的一部分）。

为什么要有这条：M0 重构把「唯一人工维护的配置」收敛到 config/orgflow.yml，
所有 IP/端口/口令/域名都从它派生。派生链断裂时的表现是「改了配置没生效」
或「容器起不来但没人知道是哪一项没渲染」，比语法错更难查。所以这里断言三件事：

1. config/orgflow.yml 与 config/services.yml 的**结构**：必填键齐备、无重复 IP、
   无重复 start_order、根 compose 的 include 与服务登记表一一对应；
2. **没有写死的地址**：compose 片段里不允许出现 `172.31.0.` 字面量（必须 ${IP_xxx}），
   根 compose 的网络段必须来自 ${NETWORK_*}，网关端口必须来自 ${GATEWAY_*_PORT}；
3. **渲染是无损的**：env_pairs 生成的键必须覆盖 compose 里出现的所有 ${VARS}，
   否则 compose 读到空字符串而静默走默认值。

反证（改坏一处必须红，恢复后复绿）：
  - 把 config/services.yml 里 ldap 的 ip 改成与 jenkins 相同 → 结构断言红；
  - 在 services/ldap/compose.yml 里把 `${IP_LDAP}` 改成 `172.31.0.22` → 写死地址断言红；
  - 从 scripts/lib/config.py 的 env_pairs 删掉 IP_LDAP 的生成 → 覆盖断言红；
  - 把 config/orgflow.yml 里 oauth2.cookie_secret 改成 8 位 → 结构断言红。
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import config as cfgmod  # noqa: E402
import rendered_values  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

REQUIRED_TOP = {
    "gateway": ["domain", "http_port", "https_port"],
    "network": ["name", "subnet", "ip_range"],
    "ldap": ["organisation", "base_dn", "admin_id", "password"],
    "mail": ["domain"],
    "jenkins": ["admin_id"],
    "nexus": ["admin_id", "password"],
    "oauth2": ["client_id", "client_secret", "cookie_secret"],
    "backup": ["dir", "retention_days"],
    "directory": ["users_ou", "groups_ou", "departments_ou", "apps_ou"],
}

SERVICE_REQUIRED = ["ip", "start_order", "container", "compose"]

PLACEHOLDER_RE = re.compile(r"\$\{([A-Z0-9_]+)(?::-[^}]*)?\}")
# 这些变量由部署脚本 / harness 在运行时 export，不来自 runtime.env
RUNTIME_ONLY = {
    "DOCKER_GID",
    "JENKINS_AGENT_SSH_PRIVATE_KEY",
    "JENKINS_AGENT_HOST_KEY",
    "COMPOSE_PROJECT_NAME",
    "KEEP",
}


def _compose_placeholders(path: Path) -> set[str]:
    """只统计 compose 语义下的占位符：注释行整行跳过。"""
    found: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("#"):
            continue
        found |= set(PLACEHOLDER_RE.findall(line))
    return found


def _compose_files() -> list[Path]:
    files = [ROOT / "docker-compose.yml"]
    files += sorted((ROOT / "services").glob("*/compose.yml"))
    files += sorted((ROOT / "tools").glob("*/compose.yml"))
    return [p for p in files if p.exists()]


class ConfigStructureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cfg = cfgmod.load()
        cls.registry = cfgmod.load_services()
        cls.services = cls.registry["services"]

    def test_required_keys_present(self) -> None:
        for section, keys in REQUIRED_TOP.items():
            self.assertIn(section, self.cfg, f"config 缺少 {section} 段")
            for key in keys:
                self.assertIsNotNone(self.cfg[section].get(key), f"config 缺少 {section}.{key}")

    def test_ports_are_integers_in_range(self) -> None:
        gw = self.cfg["gateway"]
        for key in ("http_port", "https_port"):
            port = gw[key]
            self.assertIsInstance(port, int, f"gateway.{key} 必须是整数（不要加引号）")
            self.assertTrue(1 <= port <= 65535, f"gateway.{key}={port} 越界")

    def test_cookie_secret_length(self) -> None:
        cookie = str(self.cfg["oauth2"]["cookie_secret"])
        self.assertIn(len(cookie), (16, 24, 32), f"oauth2.cookie_secret 必须是 16/24/32 字节，当前 {len(cookie)}")

    def test_passwords_not_empty(self) -> None:
        for key in ("ldap.password", "nexus.password", "oauth2.client_secret"):
            self.assertTrue(str(cfgmod._dig(self.cfg, key) or ""), f"{key} 不能为空")

    def test_service_specs_complete(self) -> None:
        for name, spec in self.services.items():
            for key in SERVICE_REQUIRED:
                self.assertIn(key, spec, f"services.{name} 缺少 {key}")
            rel = spec["compose"]
            self.assertTrue((ROOT / rel).is_file(), f"服务 {name} 的 compose 片段不存在：{rel}")

    def test_services_have_unique_ip_and_order(self) -> None:
        seen_ip: dict[str, str] = {}
        seen_order: dict[str, str] = {}
        for name, spec in self.services.items():
            ip = str(spec["ip"])
            order = str(spec["start_order"])
            self.assertNotIn(ip, seen_ip, f"IP 末段 {ip} 被 {seen_ip.get(ip)} 与 {name} 同时占用")
            self.assertNotIn(order, seen_order, f"start_order {order} 被 {seen_order.get(order)} 与 {name} 同时占用")
            seen_ip[ip] = name
            seen_order[order] = name

    def test_start_order_is_serializable(self) -> None:
        order = cfgmod.start_order(self.registry)
        self.assertGreaterEqual(len(order), 10, f"串行启动至少 10 个服务，当前 {len(order)}")
        values = [int(self.services[n]["start_order"]) for n in order]
        self.assertEqual(values, sorted(values), f"start_order 返回的顺序不是升序：{order}")

    def test_fixed_ip_inside_subnet(self) -> None:
        import ipaddress

        net = ipaddress.ip_network(str(self.cfg["network"]["subnet"]), strict=True)
        rng = str(self.cfg["network"].get("ip_range") or "")
        for name, spec in self.services.items():
            addr = ipaddress.ip_address(cfgmod.fixed_ip(self.cfg, spec))
            self.assertIn(addr, net, f"服务 {name} 的地址 {addr} 落在网段外")
            if rng:
                dyn = ipaddress.ip_network(rng, strict=True)
                self.assertNotIn(addr, dyn, f"服务 {name} 的地址 {addr} 落在动态分配段内，可能与 bridge 抢地址")

    def test_included_compose_matches_registry(self) -> None:
        """根 compose 的 include 必须与服务登记表一一对应（多一个少一个都红）。"""
        text = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        included = set(re.findall(r"^\s*-\s+(\S+/compose\.yml)\s*$", text, re.M))
        expected = {spec["compose"] for spec in self.services.values()}
        expected |= {spec["compose"] for spec in (self.registry.get("tools") or {}).values()}
        self.assertEqual(
            included,
            expected,
            f"include 与服务登记表不一致：少 {sorted(expected - included)} 多 {sorted(included - expected)}",
        )


class NoHardcodedAddressTest(unittest.TestCase):
    def test_compose_has_no_hardcoded_subnet_ip(self) -> None:
        offenders = []
        for path in _compose_files():
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if re.search(r"\b172\.31\.0\.\d+", line):
                    offenders.append(f"{path.relative_to(ROOT)}:{lineno}: {line.strip()}")
        self.assertEqual(offenders, [], "compose 里写死了网络地址，必须用 ${IP_xxx}：\n" + "\n".join(offenders))

    def test_root_compose_network_from_config(self) -> None:
        text = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        for var in ("${NETWORK_SUBNET}", "${NETWORK_IP_RANGE}", "${NETWORK_NAME"):
            self.assertIn(var, text, f"docker-compose.yml 的网络段必须用 {var}")

    def test_fragment_relative_paths_anchor_at_repo_root(self) -> None:
        """片段里的相对宿主路径必须用 ../.. 锚到仓根，不能写 ./xxx。

        docker compose 的 include 语义把片段当独立项目解析相对路径，片段里写
        ./out 会变成 services/<x>/out（不存在的目录）——bind 静默得到空目录，
        症状是「配置读不到 / 容器 unhealthy」。2026-11-22 实测 router 就是
        因为 ./config 变成 services/router/config 而一直起不来。
        """
        bad = []
        for path in _compose_files():
            if path == ROOT / "docker-compose.yml":
                continue
            want = "../" * (len(path.relative_to(ROOT).parts) - 1)
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                m = re.match(r"^\s*- \./(\S+):", line)
                if m:
                    bad.append(f"{path.relative_to(ROOT)}:{lineno} 应写 {want}{m.group(1)}：{line.strip()}")
        self.assertEqual(bad, [], "片段的相对宿主路径必须锚到仓根：\n" + "\n".join(bad))

    def test_gateway_ports_from_config(self) -> None:
        text = (ROOT / "services/caddy/compose.yml").read_text(encoding="utf-8")
        self.assertIn("${GATEWAY_HTTP_PORT}", text, "caddy 的宿主端口必须来自配置")
        self.assertIn("${GATEWAY_HTTPS_PORT}", text, "caddy 的宿主端口必须来自配置")


class RenderCoverageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.cfg = cfgmod.load()
        self.registry = cfgmod.load_services()

    def test_env_pairs_cover_every_compose_var(self) -> None:
        produced = set(cfgmod.env_pairs(self.cfg, self.registry))
        needed: set[str] = set()
        for path in _compose_files():
            needed |= _compose_placeholders(path)
        missing = sorted(needed - produced - RUNTIME_ONLY)
        self.assertEqual(missing, [], f"compose 引用了这些变量但渲染不产出：{missing}")

    def test_ip_vars_match_services(self) -> None:
        pairs = cfgmod.env_pairs(self.cfg, self.registry)
        for name in self.registry["services"]:
            key = f"IP_{name.upper().replace('-', '_')}"
            self.assertIn(key, pairs, f"渲染结果缺少 {key}")
        for name, spec in (self.registry.get("external") or {}).items():
            if "ip" in spec:
                key = f"IP_{name.upper().replace('-', '_')}"
                self.assertIn(key, pairs, f"外部服务 {name} 缺少 {key}")

    def test_plaintext_secret_not_in_log_output(self) -> None:
        """`python3 scripts/lib/config.py` 的摘要输出里不得出现口令明文。"""
        import subprocess

        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts/lib/config.py")],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
            check=True,
        ).stdout
        for dotted in ("ldap.password", "nexus.password", "oauth2.client_secret", "oauth2.cookie_secret"):
            value = str(cfgmod._dig(self.cfg, dotted) or "")
            if len(value) >= 4:
                self.assertNotIn(value, out, f"config.py 摘要输出泄漏了 {dotted}")


class RuntimeEnvPayloadTest(unittest.TestCase):
    """渲染出来的 runtime.env 喂给 compose 之后不能悄悄变空。

    背景（2026-11-22 的真缺陷）：compose 的 env 文件解析器把「不带引号且含逗号
    的值」当错误，而且只在文件里出现第二个键时才暴露 —— 爆掉之后它丢掉**整份
    载荷**，于是容器里 LDAP_BASE_DN 与 LDAP_ADMIN_DN 一起变成空串，ldap 的
    healthcheck 拿空 DN 去 bind，永远 `ldap_bind: Invalid credentials (49)`，
    整栈起不来。这条门禁在纯 python 里钉住「逗号值必须加引号」。
    """

    def test_values_with_commas_are_quoted(self) -> None:
        pairs = cfgmod.env_pairs(cfgmod.load(), cfgmod.load_services())
        for key in ("LDAP_BASE_DN", "LDAP_ADMIN_DN"):
            self.assertIn(key, pairs)
            value = rendered_values.quote(pairs[key])
            self.assertTrue(
                value.startswith('"') and value.endswith('"'),
                f"{key} 含逗号必须加引号，实际是 {value}",
            )
            self.assertIn(",", value)

    def test_ldap_password_meets_the_strictest_floor(self) -> None:
        """配置里的口令必须过长度的下限，否则第 4 步（LDAP 用户口令）才炸。

        2026-11-22 真事故：orgflow.yml 写 6 位口令，make deploy 通过、
        make init 也在第 4 步前全绿，直到 11-ldap-set-passwords.sh 才报
        「口令至少 12 字符」—— 部署跑到一半才发现配置不合格。
        """
        cfg = cfgmod.load()
        value = str(cfg["ldap"]["password"])
        self.assertGreaterEqual(len(value), cfgmod.LDAP_PASSWORD_MIN,
                                f"ldap.password 至少 {cfgmod.LDAP_PASSWORD_MIN} 字符（当前 {len(value)}）")
        pairs = cfgmod.env_pairs(cfg, cfgmod.load_services())
        self.assertEqual(pairs["LDAP_USER_PASSWORD"], value)
        self.assertEqual(pairs["LDAP_ADMIN_PASSWORD"], value)

    def test_ldif_generator_uses_the_same_floor(self) -> None:
        """生成脚本不能自己另写一个下限数字（那是第二个真源）。"""
        source = (cfgmod.ROOT / "scripts" / "11-gen-ldif-passwords.py").read_text(encoding="utf-8")
        self.assertIn("cfgmod.LDAP_PASSWORD_MIN", source)
        self.assertNotRegex(source, r"MIN_LENGTH\s*=\s*\d+")

    def test_plain_values_stay_unquoted(self) -> None:
        self.assertEqual(rendered_values.quote("dc=devops,dc=com").strip('"'), "dc=devops,dc=com")
        self.assertEqual(rendered_values.quote("org-devops.com"), "org-devops.com")
        self.assertEqual(rendered_values.quote("443"), "443")
        self.assertEqual(rendered_values.quote(""), "")

    def test_quote_escapes_shell_signs(self) -> None:
        self.assertEqual(rendered_values.quote('a b'), '"a b"')
        self.assertEqual(rendered_values.quote('pa"ss'), '"pa\\"ss"')
        self.assertEqual(rendered_values.quote("pa$$word"), '"pa$$word"')


class HarnessEnvTest(unittest.TestCase):
    """测试栈的 env 文件要补出 ldap healthcheck 依赖的 DN 键。

    2026-11-22 实测：harness 的 m0.env 是 .env.example 的拷贝，里面没有
    LDAP_BASE_DN / LDAP_ADMIN_DN，ldap 容器拿空 DN 去 bind，整栈卡在
    ldap unhealthy（日志 `op=0 BIND dn=""` + err 49）。修法是让 harness
    按配置补齐这两个键，因此这里守住「配置能给出它们」。
    """

    def test_config_cli_exposes_ldap_dns(self) -> None:
        result = subprocess.run(
            [sys.executable, str(cfgmod.__file__), "env-ldap"],
            capture_output=True, text=True, cwd=str(cfgmod.ROOT), timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        pairs = dict(
            line.split("\t", 1) for line in result.stdout.splitlines() if "\t" in line
        )
        cfg = cfgmod.load()
        self.assertEqual(pairs["LDAP_BASE_DN"], cfgmod.base_dn(cfg))
        self.assertEqual(pairs["LDAP_ADMIN_DN"], cfgmod.admin_dn(cfg))
        self.assertIn("dc=", pairs["LDAP_BASE_DN"])

    def test_harness_renders_from_the_single_source(self) -> None:
        """harness 必须走 10-render-config.sh，不能拿 .env.example 当基础。

        2026-11-22 本地 DinD 实测：.env.example 只有配置的一小部分 —— 缺
        LDAP_BASE_DN / LDAP_ADMIN_DN（ldap healthcheck 拿空 DN bind）与
        NETWORK_SUBNET / IP_*（compose 插值成空串）。所以这里钉的是
        「渲染链存在且被调用」，而不是某个键怎么拼。
        """
        entrypoint = (cfgmod.ROOT / "tests" / "harness" / "entrypoint.sh").read_text(encoding="utf-8")
        self.assertIn("scripts/10-render-config.sh", entrypoint)
        self.assertIn("/repo/out/runtime.env", entrypoint)
        # 渲染产物必须覆盖 compose 引用的每个变量，否则 compose 静默插值成空串
        self.assertIn("渲染产物缺少 compose 引用的变量", entrypoint)
        # DN 带逗号：写进 dotenv 必须加引号，否则解析器会丢掉整份载荷
        rendered = (cfgmod.ROOT / "scripts" / "lib" / "rendered_values.py").read_text(encoding="utf-8")
        self.assertIn("def quote", rendered)

    def test_ldap_healthcheck_needs_the_dns(self) -> None:
        fragment = (cfgmod.ROOT / "services" / "ldap" / "compose.yml").read_text(encoding="utf-8")
        self.assertIn("$$LDAP_BASE_DN", fragment)
        self.assertIn("$$LDAP_ADMIN_DN", fragment)
        # 口令只能经管道喂给 ldapsearch：-w 会把口令写进 docker inspect
        self.assertIn('-y /dev/stdin', fragment)
        self.assertNotIn("-w ", fragment)


class RedactionTest(unittest.TestCase):
    """日志脱敏必须按「真值」比，不能按 runtime.env 里的字面量比。

    背景（2026-11-22）：runtime.env 里含逗号/空格的值是带双引号的，脱敏脚本却
    原样拿 `"abc123"`（带引号）去 replace 日志 —— 日志里的口令因此没被替换，
    属于审计事故。
    """

    def _redact(self, payload: str, runtime_env: str) -> str:
        runtime = Path(tempfile.mkdtemp()) / "runtime.env"
        runtime.write_text(runtime_env, encoding="utf-8")
        # 从 orgflow_redact 里摘出内联 python（脚本里是 python3 -c '...' 单引号片段）
        source = (cfgmod.ROOT / "scripts" / "lib" / "runtime.sh").read_text(encoding="utf-8")
        start = source.index("orgflow_redact()")
        start = source.index("python3 -c '", start) + len("python3 -c '")
        end = source.index("\n'\n}", start)
        code = source[start:end].replace("\\'", "'")
        env = dict(os.environ)
        env["ORGFLOW_SECRETS"] = "\n".join(
            line for line in runtime_env.splitlines() if not line.startswith("#"))
        result = subprocess.run(["python3", "-c", code], input=payload, text=True,
                                capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_redaction_uses_the_unquoted_value(self) -> None:
        out = self._redact("口令 abc123 与 zzz999\n",
                           'LDAP_USER_PASSWORD="abc123"\nOAUTH2_COOKIE_SECRET=zzz999\n')
        self.assertNotIn("abc123", out)
        self.assertNotIn("zzz999", out)
        self.assertIn("[REDACTED]", out)

    def test_redaction_keeps_ordinary_text(self) -> None:
        out = self._redact("dc=devops,dc=com 不是口令\n", 'LDAP_USER_PASSWORD="abc123"\n')
        self.assertIn("dc=devops,dc=com", out)


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
