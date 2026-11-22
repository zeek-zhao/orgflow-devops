#!/usr/bin/env bash
# 20-gen-ca.sh —— 内部 CA：生成一次，证书入库，之后只读复用。
#
# 与重构前的关键差别：
#   以前用 Caddy 的 `tls internal`（local_certs），根证书由 Caddy 在数据卷里自签，
#   于是 ① 有效期只有几天/几周、② `docker compose down -v` 删卷就换一把新的、
#   ③ out/ca/root.crt 是产物、不进 git —— 每台客户端都要重装一次根证书。
#
#   现在：**根证书** config/ca/orgflow-ca.crt 入库（有效期 10 年，到 2036），客户端
#   只要装一次，重建栈、换机器都不用重装；每个子域的叶子证书由 scripts/lib/site_certs.py
#   用 CA 私钥现签（services/router/render.py 渲染 `tls /certs/sites/<子域>.crt|key`）。
#
#   私钥放哪：**不进 git**。默认写 ./secrets/ca/orgflow-ca.key（gitignore、0600），
#   部署机自己留着就能重建栈；想在多台机器间搬运，把 secrets/ca/ 一起带走即可。
#   （M0 期间曾把私钥也入库，门禁 check-public-redaction 与 gitleaks 都按私钥块拦，
#    且公开仓里的私钥等于已泄漏 —— 所以改成不入库，仓库里只有证书。）
#
# 缺文件才生成：**绝不覆盖**已有 CA —— 覆盖等于所有已装根证书的客户端立刻失效。
#
# 用法：
#   bash scripts/20-gen-ca.sh          # 缺文件则生成，齐全则跳过
#   FORCE=1 bash scripts/20-gen-ca.sh  # 仅在明确要换 CA 时用（所有客户端需重装）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/runtime.sh
. "$ROOT/scripts/lib/runtime.sh"

CA_DIR="${CA_DIR:-$ROOT/config/ca}"
CRT="$CA_DIR/orgflow-ca.crt"
# 私钥默认放 secrets/ca/（gitignore），可用 CA_KEY_DIR 覆盖。
KEY="${CA_KEY:-${CA_KEY_DIR:-$ROOT/secrets/ca}/orgflow-ca.key}"
DAYS="${CA_DAYS:-3650}"

if [ -s "$CRT" ] && [ -s "$KEY" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "  CA 已存在（$(basename "$CRT")），复用，不重新生成"
  echo "    到期：$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo '（取不到，openssl 不可用）')"
  exit 0
fi

command -v openssl >/dev/null || orgflow_fail "需要 openssl 生成 CA"
mkdir -p "$CA_DIR" "$(dirname "$KEY")"

domain="$(orgflow_env_value GATEWAY_DOMAIN)"
subjects=(
  "CN=orgflow-devops internal CA"
  "O=orgflow-devops"
  "OU=M0 platform"
)

echo "== 生成内部 CA（有效期 ${DAYS} 天）=="
openssl genrsa -out "$KEY" 4096 >/dev/null 2>&1
openssl req -x509 -new -nodes -sha256 -days "$DAYS" \
  -key "$KEY" -out "$CRT" \
  -subj "/${subjects[0]}/$(printf '%s/' "${subjects[@]:1}" | sed 's:/$::')" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1

chmod 0644 "$CRT"
chmod 0600 "$KEY"

echo "✓ 已生成 $CRT（证书，入库）"
echo "✓ 已生成 $KEY（私钥，不进 git，备份到安全的地方）"
echo "  到期：$(openssl x509 -in "$CRT" -noout -enddate | sed 's/notAfter=//')"
echo "  指纹：$(openssl x509 -in "$CRT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
echo "  ⚠ 这是**内部测试用** CA，不用于任何对外服务；真要上线换企业 CA 或 ACME。"
echo "  客户端安装：make ca-install（或 https://ca.${domain}/root.crt）"
