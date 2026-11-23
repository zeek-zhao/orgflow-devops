#!/usr/bin/env bash
# git-push.sh —— 穿透 GFW/云代理的可靠推送封装
#
# 背景：本沙箱出网经腾讯云 GA 代理（github.com 被解析到 43.139.79.x），
#       git 默认 HTTP/2 走该代理会间歇性 502；HTTP/1.1 稳定 200。
#       同时 credential helper（gh auth）在非交互环境读不到 token。
#
# 方案：强制 HTTP/1.1 + 用 GIT_TOKEN 环境变量构造 Basic auth 头（禁用 credential helper）。
#
# 用法：
#   GIT_TOKEN=<pat> bash scripts/git-push.sh [remote] [refspec...]
#   GIT_TOKEN=<pat> bash scripts/git-push.sh origin fix/ldap-bootstrap
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TOKEN="${GIT_TOKEN:-${GH_TOKEN:-}}"
[[ -n "$TOKEN" ]] || { echo "✗ 需设置 GIT_TOKEN 或 GH_TOKEN" >&2; exit 2; }

REMOTE="${1:-origin}"
if [[ "$REMOTE" == "origin" ]]; then
  shift 2>/dev/null || true
  URL="$(git remote get-url origin)"
  # 归一化为 https://github.com/... （去掉内嵌凭据）
  URL="$(printf '%s' "$URL" | sed -E 's#https://[^@]+@#https://#')"
else
  URL="$REMOTE"
  shift
fi

# 未给 refspec：推当前分支
if [[ $# -eq 0 ]]; then
  set -- "$(git branch --show-current)"
fi

AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)"
echo "[git-push] HTTP/1.1 + Basic auth → $URL (refs: $*)"
git -c http.version=HTTP/1.1 \
    -c credential.helper= \
    -c "http.extraHeader=$AUTH" \
    push "$URL" "$@"
