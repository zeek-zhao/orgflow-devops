#!/usr/bin/env bash
# =============================================================================
# 渲染 dex 配置：模板 + 域名 → out/dex/config.yaml
#
#   为什么不在 dex 容器里渲染：dex 是 scratch 镜像，没有 shell。
#   issuer 与 redirectURIs 必须是浏览器实际访问的绝对 URL，
#   所以放在部署侧渲染，域名一变重新跑一次即可。
#
#   用法：scripts/render-dex.sh [--domain example.com]
#         GATEWAY_DOMAIN 环境变量优先于 .env
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
TEMPLATE="$ROOT/services/auth/dex/config.yaml.tmpl"
OUTPUT="$ROOT/out/dex/config.yaml"

domain="${GATEWAY_DOMAIN:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) domain="${2:-}"; shift 2 ;;
        *) echo "用法：$0 [--domain <域名后缀>]" >&2; exit 2 ;;
    esac
done

# 环境变量 > .env > 模板默认值
if [[ -z "$domain" && -f "$ENV_FILE" ]]; then
    domain="$(sed -n 's/^GATEWAY_DOMAIN=//p' "$ENV_FILE" | tail -1 | tr -d '\042\047' | tr -d '[:space:]')"
fi
domain="${domain:-org-devops.com}"

[[ -f "$TEMPLATE" ]] || { echo "模板不存在：$TEMPLATE" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"

issuer="https://dex.${domain}/dex"
redirect="https://auth.${domain}/oauth2/callback"

sed -e "s|__DEX_ISSUER__|${issuer}|g" \
    -e "s|__OAUTH2_REDIRECT_URI__|${redirect}|g" \
    "$TEMPLATE" > "$OUTPUT"

# 自检：占位符必须被清空，否则 dex 会带着字面量启动
if grep -q '__DEX_ISSUER__\|__OAUTH2_REDIRECT_URI__' "$OUTPUT"; then
    echo "渲染失败：$OUTPUT 仍有未替换的占位符" >&2
    exit 1
fi

echo "已渲染 $OUTPUT"
echo "  issuer      = $issuer"
echo "  redirectURI = $redirect"
