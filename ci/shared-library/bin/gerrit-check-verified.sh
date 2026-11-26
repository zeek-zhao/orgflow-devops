#!/usr/bin/env bash
# 查询 Gerrit change 的 Verified 标签值（M2.4 Phase3 评审流探针用）。
# 依赖 env：GERRIT_KEY（ci-bot 私钥路径，由 Jenkins withCredentials 注入）；可选 KH/HOST。
# 输出：命中 Verified 的 "value":"N" 行（供调用方 grep 判定）；无命中则空。
# 说明：从 orgflow-agent 执行，host key 固定校验（known_hosts 落卷），不用 StrictHostKeyChecking=no。
set -uo pipefail
CHANGE="${1:-}"
KH="${KH:-/opt/orgflow/config/known_hosts}"
HOST="${GERRIT_HOST:-gerrit}"
[[ -n "$CHANGE" && -n "${GERRIT_KEY:-}" ]] || { echo "usage: gerrit-check-verified.sh <change> (需 GERRIT_KEY)" >&2; exit 2; }

ssh -i "$GERRIT_KEY" -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -p 29418 "ci-bot@$HOST" \
  "gerrit query --format=JSON --all-approvals change:${CHANGE}" 2>/dev/null \
  | tr ',' '\n' | grep -A2 'Verified' | grep '"value"' | head -1
