#!/usr/bin/env bash
# cgit-refresh.sh —— 刷新 cgit 的 projects.list（文档 §M2.1）
#
# 从 Gerrit 裸库目录扫 *.git，写 projects.list。可在 Jenkins 定时 Job 里执行（留痕，推荐），
# 也可在宿主机对 gerrit_git 卷执行一次。与 cgit entrypoint 的 5 分钟刷新互为兜底。
#
# 用法（在能访问 gerrit_git 卷的容器/宿主机执行）：
#   GIT_ROOT=/var/gerrit/git LIST_OUT=/tmp/projects.list bash scripts/cgit-refresh.sh
set -euo pipefail
GIT_ROOT="${GIT_ROOT:-/var/gerrit/git}"
LIST_OUT="${CGIT_PROJECTS_LIST:-/tmp/projects.list}"

[[ -d "$GIT_ROOT" ]] || { echo "GIT_ROOT 不存在: $GIT_ROOT" >&2; exit 1; }
tmp="${LIST_OUT}.tmp.$$"
: > "$tmp"
find "$GIT_ROOT" -maxdepth 1 -name '*.git' -printf '%f\n' 2>/dev/null | sort >> "$tmp"
mv "$tmp" "$LIST_OUT"
echo "✓ projects.list 已刷新（$(wc -l < "$LIST_OUT") 个仓库）→ $LIST_OUT"
