#!/usr/bin/env python3
"""配置读取的唯一入口：config/orgflow.yml + config/services.yml → 结构化对象。

为什么要有这个模块：重构前每条事实都散在多处——域名在 .env、固定 IP 在
docker-compose.yml、容器名在脚本里硬编码、启动顺序在 deploy.sh 的 start_batch 里。
改一处忘一处，排查时看到的是"三份互相矛盾的真相"。

现在：
  config/orgflow.yml   人写的配置（域名/端口/网段/路径/口令）
  config/services.yml  架构常量（服务名/容器名/固定 IP/启动顺序/依赖）
  out/runtime.env      渲染产物，给 compose 的 ${VAR} 插值用（不进 git，0600）

脚本里一律 `from config import load`，不要再用 `grep .env` 或写死 IP。
"""
from __future__ import annotations

import ipaddress
import os
import pathlib
import re
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]

CONFIG_FILE = ROOT / "config" / "orgflow.yml"
SERVICES_FILE = ROOT / "config" / "services.yml"

# 敏感键：打印与日志里一律掩码，只留「有没有值」
SECRET_KEYS = (
    "LDAP_ADMIN_PASSWORD",
    "LDAP_USER_PASSWORD",
    "NEXUS_ADMIN_PASSWORD",
    "OAUTH2_CLIENT_SECRET",
    "OAUTH2_COOKIE_SECRET",
    "GITHUB_TOKEN",
)


class ConfigError(SystemExit):
    """配置错误：带明确修法，别让调用方猜。"""

    def __init__(self, message: str) -> None:
        super().__init__(f"✗ 配置错误：{message}\n  修：改 config/orgflow.yml 或 config/services.yml 后重跑")


def _load_yaml(path: pathlib.Path) -> dict[str, Any]:
    """只用标准库能读的子集（缩进映射 + 标量 + 列表），避免给部署机加依赖。

    这不是通用 YAML 解析器：仓库里的配置文件由我们自己写，格式受控。
    遇到不认识的写法**直接报错**，而不是静默丢字段 —— 静默丢配置是排查最贵的一类 bug。
    """
    try:
        import yaml  # type: ignore[import-not-found]
    except ModuleNotFoundError:
        return _mini_yaml(path)
    with path.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    return data or {}


def _mini_yaml(path: pathlib.Path) -> dict[str, Any]:
    """极简 YAML 读取：两级缩进映射 + 标量。部署机没装 PyYAML 时用它。"""
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(-1, root)]
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split(" #", 1)[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        body = line.strip()
        key, sep, value = body.partition(":")
        if not sep:
            raise ConfigError(f"{path}:{lineno} 不是 key: value 形式：{body!r}")
        while stack and indent <= stack[-1][0]:
            stack.pop()
        if not stack:
            raise ConfigError(f"{path}:{lineno} 缩进不合法")
        parent = stack[-1][1]
        value = value.strip()
        if value == "":
            child: dict[str, Any] = {}
            parent[key.strip()] = child
            stack.append((indent, child))
        else:
            parent[key.strip()] = _scalar(value)
    return root


def _scalar(text: str) -> Any:
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    return text


def load(path: pathlib.Path | None = None) -> dict[str, Any]:
    cfg_file = path or CONFIG_FILE
    if not cfg_file.exists():
        raise ConfigError(f"缺少 {cfg_file}（这是唯一人工维护的配置文件）")
    data = _load_yaml(cfg_file)
    for key in ("gateway", "network", "ldap", "jenkins", "nexus", "oauth2", "backup", "directory"):
        if key not in data:
            raise ConfigError(f"{cfg_file.name} 缺少 `{key}:` 段")
    _validate(data)
    return data


def load_services(path: pathlib.Path | None = None) -> dict[str, Any]:
    svc_file = path or SERVICES_FILE
    if not svc_file.exists():
        raise ConfigError(f"缺少 {svc_file}（服务注册表）")
    data = _load_yaml(svc_file)
    services = data.get("services") or {}
    if not services:
        raise ConfigError(f"{svc_file.name} 的 services: 为空")
    seen_ip: dict[int, str] = {}
    for name, spec in services.items():
        if "ip" not in spec:
            raise ConfigError(f"services.{name} 缺少 ip（固定 IP 的末段）")
        ip = int(spec["ip"])
        if ip in seen_ip:
            raise ConfigError(f"services.{name} 与 {seen_ip[ip]} 撞 IP：. {ip}")
        seen_ip[ip] = name
    orders = [int(s["start_order"]) for s in services.values()]
    if len(set(orders)) != len(orders):
        raise ConfigError("services.*.start_order 有重复值，串行顺序不确定")
    return data


def _validate(cfg: dict[str, Any]) -> None:
    domain = str(cfg["gateway"].get("domain") or "")
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+", domain):
        raise ConfigError(f"gateway.domain 不是合法域名：{domain!r}")
    for key in ("http_port", "https_port"):
        port = cfg["gateway"].get(key)
        if not isinstance(port, int) or not 1 <= port <= 65535:
            raise ConfigError(f"gateway.{key} 必须是 1-65535 的整数，当前 {port!r}")
    if cfg["gateway"]["http_port"] == cfg["gateway"]["https_port"]:
        raise ConfigError("gateway.http_port 与 https_port 不能相同")
    try:
        net = ipaddress.ip_network(str(cfg["network"].get("subnet")), strict=True)
    except ValueError as exc:
        raise ConfigError(f"network.subnet 不合法：{exc}") from exc
    rng = str(cfg["network"].get("ip_range") or "")
    if rng:
        try:
            ipaddress.ip_network(rng, strict=True)
        except ValueError as exc:
            raise ConfigError(f"network.ip_range 不合法：{exc}") from exc
        if not ipaddress.ip_network(rng, strict=True).subnet_of(net):
            raise ConfigError("network.ip_range 必须落在 network.subnet 内")
    base_dn = str(cfg["ldap"].get("base_dn") or "")
    if not re.fullmatch(r"(dc=[a-z0-9-]+,)+dc=[a-z0-9-]+", base_dn):
        raise ConfigError(f"ldap.base_dn 必须形如 dc=devops,dc=com，当前 {base_dn!r}")
    for key in ("ldap.password", "nexus.password", "oauth2.client_secret"):
        if not str(_dig(cfg, key) or ""):
            # 空口令不许上线：宁可部署失败，也不要一个空密码的管理入口
            raise ConfigError(f"{key} 不能为空")
    cookie = str(cfg["oauth2"].get("cookie_secret") or "")
    if len(cookie) not in (16, 24, 32):
        raise ConfigError(f"oauth2.cookie_secret 必须是 16/24/32 字节（oauth2-proxy 要求），当前 {len(cookie)}")


def _dig(cfg: dict[str, Any], dotted: str) -> Any:
    node: Any = cfg
    for part in dotted.split("."):
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def fixed_ip(cfg: dict[str, Any], spec: dict[str, Any]) -> str:
    """固定 IP 由 network.subnet 的网络前缀 + spec.ip 拼出来，不手抄整段地址。"""
    net = ipaddress.ip_network(str(cfg["network"]["subnet"]), strict=True)
    return str(net.network_address + int(spec["ip"]))


def base_dn(cfg: dict[str, Any]) -> str:
    return str(cfg["ldap"]["base_dn"])


def users_dn(cfg: dict[str, Any]) -> str:
    return f"{cfg['directory']['users_ou']},{base_dn(cfg)}"


def groups_dn(cfg: dict[str, Any]) -> str:
    return f"{cfg['directory']['groups_ou']},{base_dn(cfg)}"


def admin_dn(cfg: dict[str, Any]) -> str:
    return f"cn={cfg['ldap']['admin_id']},{base_dn(cfg)}"


def site(cfg: dict[str, Any], subdomain: str) -> str:
    """站点的宿主侧地址：非 443 端口必须显式带上，否则复制出去打不开。"""
    port = int(cfg["gateway"]["https_port"])
    suffix = "" if port == 443 else f":{port}"
    return f"https://{subdomain}.{cfg['gateway']['domain']}{suffix}"


def mask(value: str) -> str:
    """日志里只显示长度与首尾，不显示值本身。"""
    if not value:
        return "(未设置)"
    if len(value) <= 4:
        return "***"
    return f"{value[0]}***{value[-1]}（{len(value)} 字符）"


# 口令下限（字符数）。M0 的口径是「所有账号一个口令」，而这个口令要同时能过
# 三道外部校验，取最严的那道：
#   - Nexus 3.92 的 PasswordValidator（DEFAULT_PASSWORD_REGEX `. {8,}`，写死在 jar 里，
#     只能靠 Spring 属性覆盖，见 scripts/70-nexus-deploy.sh）；
#   - Jenkins 的 LDAP 账号由 51-init.sh 走 ldapset 同步，无独立策略；
#   - LDAP 用户条目由 11-gen-ldif-passwords.py 生成，历史上要求 ≥12（随机路径 32 字符）。
# 三道取最严 = 12，所以配置里写 6 位会在第 4 步「设置 LDAP 用户口令」被拦下。
LDAP_PASSWORD_MIN = 12
NEXUS_PASSWORD_MIN = 8


def password_min(key: str) -> int:
    """按键名给出该口令的长度下限（门禁与脚本共用同一份数字）。"""
    return LDAP_PASSWORD_MIN if key.startswith("LDAP_") else NEXUS_PASSWORD_MIN


def env_pairs(cfg: dict[str, Any], services: dict[str, Any]) -> dict[str, str]:
    """渲染 out/runtime.env 的键值对：compose 的 ${VAR} 全部从这里取值。"""
    domain = cfg["gateway"]["domain"]
    pairs = {
        "GATEWAY_DOMAIN": domain,
        "GATEWAY_HTTP_PORT": str(cfg["gateway"]["http_port"]),
        "GATEWAY_HTTPS_PORT": str(cfg["gateway"]["https_port"]),
        "NETWORK_NAME": cfg["network"]["name"],
        "NETWORK_SUBNET": cfg["network"]["subnet"],
        "NETWORK_IP_RANGE": cfg["network"].get("ip_range") or "",
        "LDAP_ORGANISATION": cfg["ldap"]["organisation"],
        "LDAP_BASE_DN": cfg["ldap"]["base_dn"],
        "LDAP_ADMIN_ID": cfg["ldap"]["admin_id"],
        "LDAP_ADMIN_DN": admin_dn(cfg),
        "LDAP_DOMAIN": str(cfg.get("mail", {}).get("domain", "devops.com")),
        "OU_USERS": cfg["directory"]["users_ou"],
        "OU_GROUPS": cfg["directory"]["groups_ou"],
        "EMAIL_DOMAIN": cfg.get("mail", {}).get("domain", "devops.com"),
        "JENKINS_ADMIN_ID": cfg["jenkins"]["admin_id"],
        "JENKINS_URL": f"https://jenkins.{domain}/",
        "JJB_JENKINS_URL": "http://jenkins:8080/",
        "GITHUB_USER": cfg["jenkins"].get("github_user") or "",
        "GITHUB_TOKEN": cfg["jenkins"].get("github_token") or "",
        "NEXUS_ADMIN_ID": cfg["nexus"]["admin_id"],
        "OAUTH2_CLIENT_ID": cfg["oauth2"]["client_id"],
        "BACKUP_DIR": cfg["backup"]["dir"],
        "BACKUP_RETENTION_DAYS": str(cfg["backup"]["retention_days"]),
    }
    # 固定 IP：按服务名派生 IP_<SERVICE>，compose 片段里用 ${IP_JENKINS} 这种名字引用，
    # 避免同一个地址在 ten 个文件里各写一遍。
    for name, spec in (services.get("services") or {}).items():
        pairs[f"IP_{name.upper().replace('-', '_')}"] = fixed_ip(cfg, spec)
    for name, spec in (services.get("external") or {}).items():
        if "ip" in spec:
            pairs[f"IP_{name.upper().replace('-', '_')}"] = fixed_ip(cfg, spec)
    # 口令最后加，保证上面任何一处漏配都不会把口令写进半成品
    ldap_pw = str(cfg["ldap"]["password"])
    if len(ldap_pw) < LDAP_PASSWORD_MIN:
        raise ConfigError(
            f"ldap.password 至少 {LDAP_PASSWORD_MIN} 字符（当前 {len(ldap_pw)}）——"
            "它同时要过 LDAP 用户口令生成与 Nexus 密码策略，取三道里最严的 12"
        )
    pairs.update(
        {
            "LDAP_ADMIN_PASSWORD": ldap_pw,
            "LDAP_USER_PASSWORD": ldap_pw,
            "NEXUS_ADMIN_PASSWORD": str(cfg["nexus"]["password"]),
            "OAUTH2_CLIENT_SECRET": str(cfg["oauth2"]["client_secret"]),
            "OAUTH2_COOKIE_SECRET": str(cfg["oauth2"]["cookie_secret"]),
        }
    )
    return pairs


def start_order(services: dict[str, Any]) -> list[str]:
    specs = services.get("services") or {}
    return [name for name, _ in sorted(specs.items(), key=lambda kv: int(kv[1]["start_order"]))]


def main() -> int:
    import json
    import sys

    cfg = load()
    services = load_services()
    if len(sys.argv) > 1 and sys.argv[1] == "env-keys":
        # 给 harness 用：compose 需要的全部变量名（空格分隔），配合
        # 10-render-config.sh 的 RUNTIME_ENV_KEYS 只渲染测试栈要的键。
        print(" ".join(env_pairs(cfg, services)))
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "env-ldap":
        # 给 harness 用：ldap 的 healthcheck 需要这三个键做 bind + base 搜索，
        # 而测试栈的 env 文件来自 .env.example（没有它们）。一行一个 KEY<TAB>值，
        # 值不加引号（调用方按需转义），DN 里含逗号对 dotenv 是合法字符。
        for key, value in (
            ("LDAP_BASE_DN", base_dn(cfg)),
            ("LDAP_ADMIN_DN", admin_dn(cfg)),
        ):
            print(f"{key}\t{value}")
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        print(json.dumps({"config": cfg, "services": services}, ensure_ascii=False, indent=2))
        return 0
    print("== orgflow.yml 摘要 ==")
    print(f"域名          {cfg['gateway']['domain']}")
    print(f"宿主端口      {cfg['gateway']['http_port']} / {cfg['gateway']['https_port']}")
    print(f"网段          {cfg['network']['subnet']}（动态段 {cfg['network'].get('ip_range')}）")
    print(f"目录根        {cfg['ldap']['base_dn']}")
    print(f"备份目录      {cfg['backup']['dir']}（保留 {cfg['backup']['retention_days']} 天）")
    print("口令          " + "、".join(f"{k}={mask(str(cfg_value))}" for k, cfg_value in (
        ("ldap.password", cfg["ldap"]["password"]),
        ("nexus.password", cfg["nexus"]["password"]),
        ("oauth2.client_secret", cfg["oauth2"]["client_secret"]),
    )))
    print("== 启动顺序（串行） ==")
    for index, name in enumerate(start_order(services), 1):
        spec = services["services"][name]
        print(f"{index:>2}. {name:<15} {fixed_ip(cfg, spec):<13} {spec.get('why', '')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
