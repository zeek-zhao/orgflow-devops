#!/usr/bin/env bash
# =============================================================================
# 导出 Caddy 内部 CA 根证书并安装到本机信任库
#
#   Caddy 用 tls internal（local_certs）给所有站点签证书，
#   浏览器/curl 不信任它就会报 NET::ERR_CERT_AUTHORITY_INVALID。
#   这个脚本把根证书导出来，装进系统信任库。
#
#   用法：
#     scripts/ca-install.sh                      # 213 网关机：导出 out/ca/root.crt 并尝试安装
#     scripts/ca-install.sh --export             # 只导出（同时把本脚本拷进 out/ca 供远程下载）
#     scripts/ca-install.sh <https://ca.<domain>>  # 局域网其他机器：拉证书+装信任库+校验三步（#62）
#
# 远程模式说明：首次下载时本机还没信任内部 CA，这一次下载只能 -k（自举问题，
# 不是掩盖证书问题——装完会用不带 -k 的请求复验整条链路）。
# 反证保障：网关地址错 / 不可达 / 拉到的不是本环境 CA，一律非零退出并打印原因。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
OUT_DIR="$ROOT/out/ca"
CERT="$OUT_DIR/root.crt"
export_only=0
GATEWAY_URL=""

parse_args() {
    while (( $# )); do
        case "$1" in
            --export) export_only=1 ;;
            http://*|https://*) GATEWAY_URL="${1%/}" ;;
            *) echo "未知参数: $1；用法见文件头注释" >&2; exit 2 ;;
        esac
        shift
    done
}
parse_args "$@"

# ---------- 远程模式（#62）：一条命令装根证书，不依赖 docker / ssh ----------
if [[ -n "$GATEWAY_URL" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf -- "$TMP"' EXIT
    fetched="$TMP/root.crt"

    echo "拉取根证书: $GATEWAY_URL/root.crt（本次下载用 -k 自举；装完复验不用 -k）"
    if ! curl -fksS --max-time 30 "$GATEWAY_URL/root.crt" -o "$fetched"; then
        echo "失败：无法从 $GATEWAY_URL/root.crt 拉取（网关地址错？不可达？证书还没导出？）" >&2
        exit 1
    fi
    subject="$(openssl x509 -in "$fetched" -noout -subject 2>/dev/null || true)"
    if ! grep -qi "Caddy Local Authority" <<< "$subject"; then
        echo "失败：拉到的内容不是本环境 CA 根证书（subject: ${subject:-无}）" >&2
        exit 1
    fi

    installed=0
    if command -v update-ca-certificates >/dev/null 2>&1; then
        dest=/usr/local/share/ca-certificates/orgflow-caddy.crt
        if [[ -w "$(dirname "$dest")" ]]; then
            cp "$fetched" "$dest"
            update-ca-certificates >/dev/null
            installed=1
            echo "已安装到系统信任库：$dest"
        else
            echo "失败：$dest 不可写，需要 sudo（sudo bash $0 $GATEWAY_URL）" >&2
            exit 1
        fi
    elif command -v update-ca-trust >/dev/null 2>&1; then
        dest=/etc/pki/ca-trust/source/anchors/orgflow-caddy.crt
        if [[ -w "$(dirname "$dest")" ]]; then
            cp "$fetched" "$dest"
            update-ca-trust >/dev/null
            installed=1
            echo "已安装到系统信任库：$dest"
        else
            echo "失败：$dest 不可写，需要 sudo（sudo bash $0 $GATEWAY_URL）" >&2
            exit 1
        fi
    else
        echo "失败：未找到 update-ca-certificates / update-ca-trust，不支持当前发行版" >&2
        exit 1
    fi

    # 复验：不带 -k 打通网关，证明信任链真的建立
    if curl -fsS --max-time 30 "$GATEWAY_URL/root.crt" -o /dev/null; then
        echo "复验通过（不带 -k 访问 $GATEWAY_URL 成功）。浏览器重开页面即无证书警告。"
        exit 0
    fi
    echo "失败：证书已安装，但不带 -k 访问 $GATEWAY_URL 仍失败——信任链未生效" >&2
    exit 1
fi

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
# 自包含分发（#62）：把本脚本也放进 out/ca，router 会把整个目录服务出去，
# 局域网机器才能「curl 脚本 + curl 证书」一条链路走完。
if cp -- "$0" "$OUT_DIR/ca-install.sh" 2>/dev/null; then
    chmod 0644 "$OUT_DIR/ca-install.sh"
fi

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
