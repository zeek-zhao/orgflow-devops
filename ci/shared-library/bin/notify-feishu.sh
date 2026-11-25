#!/usr/bin/env bash
# E2：失败通知（飞书自定义机器人 webhook）。
# 用法：notify-feishu.sh <job> <build_number> <build_url> [status]
# webhook 由 Jenkins withCredentials 绑定 FEISHU_WEBHOOK 环境变量注入（string 凭据 id: feishu-webhook），
# 不入库、不进 compose、不进 console（curl 只发到 webhook，不回显 URL）。
set -uo pipefail

JOB="${1:-unknown}"
BUILD="${2:-0}"
URL="${3:-}"
STATUS="${4:-FAILURE}"

if [[ -z "${FEISHU_WEBHOOK:-}" ]]; then
  echo "[notify] FEISHU_WEBHOOK 未注入，跳过失败通知（E2 机制就位，配置 feishu-webhook 凭据后生效）"
  exit 0
fi

# 飞书 text 消息：标题 + 失败构建定位。
TEXT="[OrgFlow CI] ${JOB} #${BUILD} ${STATUS}
构建：${URL}
时间：$(date '+%F %T %Z')"

BODY="$(printf '{"msg_type":"text","content":{"text":"%s"}}' "$(printf '%s' "$TEXT" | sed ':a;N;$!ba;s/\n/\\n/g')")"

# -sS 静默进度但保留错误；--max-time 避免挂住构建；webhook 不回显。
if curl -sS --max-time 15 -H 'Content-Type: application/json' -d "$BODY" "$FEISHU_WEBHOOK" >/dev/null 2>&1; then
  echo "[notify] 已发送飞书失败通知：${JOB} #${BUILD}"
else
  echo "[notify] 飞书通知发送失败（不影响构建结果）"
fi
exit 0
