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

val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

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

URL_ENTRY="https://${PUBLIC_HOST}:${FUNNEL_PORT_ENTRY}"
mkdir -p "$(dirname "$OUT")"
{
  echo "# 由 scripts/render-urls.sh 生成，勿手改；公网 URL 单一真源"
  echo "PUBLIC_HOST=$PUBLIC_HOST"
  echo "URL_ENTRY=$URL_ENTRY"
  echo "URL_GERRIT=https://${PUBLIC_HOST}:${FUNNEL_PORT_GERRIT}"
  echo "URL_HARBOR=https://${PUBLIC_HOST}:${FUNNEL_PORT_HARBOR}"
  echo "URL_JENKINS=${URL_ENTRY}/jenkins/"
  echo "URL_CGIT=${URL_ENTRY}/cgit/"
  echo "BACKEND_GERRIT=http://127.0.0.1:${PUB_HTTP_GERRIT}"
  echo "BACKEND_HARBOR=http://127.0.0.1:${PUB_HTTP_HARBOR}"
  echo "BACKEND_ENTRY=http://127.0.0.1:${PUBLIC_PORT}"
} > "$OUT"
echo "✓ 已渲染 $OUT（公网 URL 单一真源）"
