#!/usr/bin/env bash
# render-urls.sh —— M2 §1：把三层端口模型渲染为 out/urls.env（公网 URL 单一真源）
#
# 为什么需要这一层：
#   M2 起公网入口有三个 Funnel 端口（门面/Gerrit/Harbor），Gerrit canonical URL、
#   cgit clone URL、Harbor 推送地址、Jenkins 回调都依赖它们。三处硬约束之一是
#   "对外端口全部可配、不得写死字面端口"，因此所有公网 URL 只从本文件生成的
#   out/urls.env 取；门禁（check-ports.sh）断言源码无字面端口、URL 与端口一致。
#
# 输入：config/defaults.env（非敏感），可被 ENV_FILE 覆盖（独立命名空间测试）。
# 输出：out/urls.env（生成物，不入库）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ENV_FILE="${ENV_FILE:-config/defaults.env}"
OUT="${OUT_URLS:-out/urls.env}"

# 公网三层端口的单一真源是 defaults.env；独立命名空间 env（tests/v2.env）只覆盖
# PUBLIC_HOST/PUBLIC_PORT 等隔离项、不含 funnel/回环端口。故缺失变量回退到
# defaults.env，使精简 env 也能渲染；线上 ENV_FILE=defaults.env 时行为完全不变。
BASE_ENV="config/defaults.env"
val() {
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
  [[ -n "$v" ]] && { echo "$v"; return; }
  [[ "$ENV_FILE" != "$BASE_ENV" ]] && grep -E "^$1=" "$BASE_ENV" 2>/dev/null | head -1 | cut -d= -f2-
}

PUBLIC_HOST="$(val PUBLIC_HOST)"
FUNNEL_PORT_ENTRY="$(val FUNNEL_PORT_ENTRY)"
FUNNEL_PORT_GERRIT="$(val FUNNEL_PORT_GERRIT)"
FUNNEL_PORT_HARBOR="$(val FUNNEL_PORT_HARBOR)"
PUBLIC_PORT="$(val PUBLIC_PORT)"
PUB_HTTP_GERRIT="$(val PUB_HTTP_GERRIT)"
PUB_HTTP_HARBOR="$(val PUB_HTTP_HARBOR)"

: "${PUBLIC_HOST:?缺少 PUBLIC_HOST}"
for v in FUNNEL_PORT_ENTRY FUNNEL_PORT_GERRIT FUNNEL_PORT_HARBOR PUBLIC_PORT PUB_HTTP_GERRIT PUB_HTTP_HARBOR; do
  : "${!v:?缺少 $v}"
done

# 443 是 https 默认端口，按 URL 规范省略，避免 URL_ENTRY/URL_JENKINS/URL_CGIT 带冗余 :443。
# 其余 Funnel 口（8443/10000）非默认端口，必须显式保留。
pub_url() {
  local port="$1"
  if [[ "$port" == "443" ]]; then
    echo "https://${PUBLIC_HOST}"
  else
    echo "https://${PUBLIC_HOST}:${port}"
  fi
}
URL_ENTRY="$(pub_url "$FUNNEL_PORT_ENTRY")"
mkdir -p "$(dirname "$OUT")"
{
  echo "# 由 scripts/render-urls.sh 生成，勿手改；公网 URL 单一真源"
  echo "PUBLIC_HOST=$PUBLIC_HOST"
  echo "URL_ENTRY=$URL_ENTRY"
  echo "URL_GERRIT=$(pub_url "$FUNNEL_PORT_GERRIT")"
  echo "URL_HARBOR=$(pub_url "$FUNNEL_PORT_HARBOR")"
  echo "URL_JENKINS=${URL_ENTRY}/jenkins/"
  echo "URL_CGIT=${URL_ENTRY}/cgit/"
  echo "BACKEND_GERRIT=http://127.0.0.1:${PUB_HTTP_GERRIT}"
  echo "BACKEND_HARBOR=http://127.0.0.1:${PUB_HTTP_HARBOR}"
  echo "BACKEND_ENTRY=http://127.0.0.1:${PUBLIC_PORT}"
} > "$OUT"
echo "✓ 已渲染 $OUT（公网 URL 单一真源）"
