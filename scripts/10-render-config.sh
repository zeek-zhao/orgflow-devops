#!/usr/bin/env bash
# 10-render-config.sh —— 把所有「配置」渲染成运行期产物。
#
# 输入（唯一人工维护）：
#   config/orgflow.yml     域名/端口/网段/备份路径/口令
#   config/services.yml    服务名/容器名/固定 IP/启动顺序
#   config/routes.yaml     站点路由
#
# 输出（产物，不进 git）：
#   out/runtime.env        给 compose 的 ${VAR} 插值（0600，含口令）
#   out/Caddyfile          网关站点配置
#   out/dex/config.yaml    OIDC 配置
#
# 为什么是这两个 YAML 而不是 .env：.env 是「一堆没人知道谁在用」的键值堆，
# 改错一个键不会有任何报错；YAML 有结构、有校验（scripts/lib/config.py），
# 渲染时就能拦住错配。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${OUT_DIR:-out}"
mkdir -p "$OUT_DIR"

echo "== 校验并渲染配置 =="
# RUNTIME_ENV_KEYS：只渲染这些键（空格分隔）。测试栈用它把「定稿的 env 文件」
# 直接变成渲染产物（out/runtime.env），避免出现「compose 用 A 文件、被测脚本
# 用 B 文件」两套变量 —— 那样脚本里的端口与栈实际发布端口可能不一致。
RUNTIME_ENV_KEYS="${RUNTIME_ENV_KEYS:-}"

python3 - "$OUT_DIR" "$RUNTIME_ENV_KEYS" <<'PY'
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path("scripts") / "lib"))
import config as cfgmod  # noqa: E402
from rendered_values import quote  # noqa: E402

out_dir = pathlib.Path(sys.argv[1])
only = set(sys.argv[2].split())
cfg = cfgmod.load()
services = cfgmod.load_services()
pairs = cfgmod.env_pairs(cfg, services)
if only:
    pairs = {key: value for key, value in pairs.items() if key in only}

target = out_dir / "runtime.env"
lines = [
    "# 本文件由 scripts/10-render-config.sh 从 config/orgflow.yml + config/services.yml 生成。",
    "# 不要手改：改配置后重跑渲染（make render）。",
    "# 含口令，权限 0600，不纳入版本控制。",
]
for key, value in pairs.items():
    lines.append(f"{key}={quote(value)}")
# 先写临时文件再原子替换：渲染中途失败时不能留下一个「半套口令」的文件
tmp = out_dir / "runtime.env.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, target)
print(f"✓ {target}（{len(pairs)} 个键，0600）")
print(f"  域名 {cfg['gateway']['domain']}  端口 {cfg['gateway']['http_port']}/{cfg['gateway']['https_port']}")
print(f"  网段 {cfg['network']['subnet']}  目录根 {cfg['ldap']['base_dn']}")
PY

# shellcheck disable=SC1091
set -a
. "$OUT_DIR/runtime.env"
set +a

echo "== 签发站点证书 =="
# 产物渲染是干净 checkout 首次运行的第一步：CA 私钥不进 git，缺失时现场生成。
# CA 已存在时脚本会复用；FORCE=1 只用于明确换根证书的场景。
bash scripts/20-gen-ca.sh
# 每个子域一张叶子证书（同一把内部 CA 签），缺失才签、已有就复用 ——
# 所以要放在渲染 Caddyfile 之前，否则 Caddyfile 会指向不存在的文件。
python3 scripts/lib/site_certs.py

echo "== 渲染网关配置 =="
python3 services/router/render.py --routes config/routes.yaml --out "$OUT_DIR/Caddyfile" --admin ""

echo "== 渲染 dex 配置 =="
GATEWAY_DOMAIN="$GATEWAY_DOMAIN" bash scripts/12-render-dex.sh >/dev/null
echo "✓ $OUT_DIR/dex/config.yaml"

echo "== 渲染完成 =="
echo "  站点：https://<子域>.${GATEWAY_DOMAIN}（子域清单见 config/routes.yaml）"
echo "  下一步：bash scripts/30-up-serial.sh  （或 make deploy）"
