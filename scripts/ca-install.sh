#!/usr/bin/env bash
# =============================================================================
# 导出 Caddy 内部 CA 根证书并安装到本机信任库
#
#   Caddy 用 tls internal（local_certs）给所有站点签证书，
#   浏览器/curl 不信任它就会报 NET::ERR_CERT_AUTHORITY_INVALID。
#   这个脚本把根证书导出来，装进系统信任库。
#
#   用法：
#     scripts/ca-install.sh            # 导出到 out/ca/root.crt 并尝试安装
#     scripts/ca-install.sh --export   # 只导出，不安装
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
OUT_DIR="$ROOT/out/ca"
CERT="$OUT_DIR/root.crt"
export_only=0
[[ "${1:-}" == "--export" ]] && export_only=1

mkdir -p "$OUT_DIR"

if ! command -v docker >/dev/null 2>&1; then
    echo "需要 docker 才能从 caddy 容器里导出根证书" >&2
    exit 1
fi

# shellcheck disable=SC2086
if ! docker compose -f "$ROOT/docker-compose.yml" --env-file "$ENV_FILE" \
        --project-directory "$ROOT" exec -T caddy \
        cat /data/caddy/pki/authorities/local/root.crt > "$CERT" 2>/dev/null; then
    echo "导出失败：caddy 容器未运行，或 /data/caddy 下还没有根证书" >&2
    echo "先跑 make deploy，再重试。" >&2
    exit 1
fi

if [[ ! -s "$CERT" ]]; then
    echo "导出失败：$CERT 是空的" >&2
    exit 1
fi
echo "已导出根证书：$CERT"
openssl x509 -in "$CERT" -noout -subject -dates 2>/dev/null | sed 's/^/  /' || true

if (( export_only )); then
    echo "只导出，不安装（--export）"
    exit 0
fi

installed=0
if command -v update-ca-certificates >/dev/null 2>&1; then
    dest=/usr/local/share/ca-certificates/orgflow-caddy.crt
    if [[ -w "$(dirname "$dest")" ]]; then
        cp "$CERT" "$dest"
        update-ca-certificates >/dev/null
        installed=1
        echo "已安装到系统信任库：$dest"
    fi
fi

if (( ! installed )) && command -v security >/dev/null 2>&1; then
    security add-trusted-cert -d -r trustRoot \
        -k "$HOME/Library/Keychains/login.keychain-db" "$CERT" && installed=1
    echo "已安装到 macOS 登录钥匙串"
fi

if (( ! installed )); then
    cat <<EOF

未自动安装（当前系统没有可用的信任库写入方式，或权限不足）。
手动安装方式：

  Debian/Ubuntu（需 sudo）
    sudo cp "$CERT" /usr/local/share/ca-certificates/orgflow-caddy.crt
    sudo update-ca-certificates

  RHEL/CentOS（需 sudo）
    sudo cp "$CERT" /etc/pki/ca-trust/source/anchors/orgflow-caddy.crt
    sudo update-ca-trust

  Windows
    双击 "$CERT" → 安装证书 → 本地计算机 → 受信任的根证书颁发机构

  Firefox（独立信任库）
    设置 → 隐私与安全 → 证书 → 查看证书 → 证书颁发机构 → 导入

  curl 临时信任（不改系统）
    curl --cacert "$CERT" https://jenkins.<domain>/
EOF
fi
