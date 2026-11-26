#!/usr/bin/env bash
# cgit-refresh.sh —— 刷新 cgit 的业务仓清单（repo. 显式白名单，文档 §M2.1）
#
# 从 Gerrit 裸库目录扫 *.git，排除 All-Projects.git/All-Users.git，生成 cgit 可 include
# 的 repo. 清单（/tmp/projects.conf）。可在 Jenkins 定时 Job 里执行（留痕，推荐），
# 也可在宿主机对 gerrit_git 卷执行一次。与 cgit entrypoint 的 5 分钟刷新互为兜底。
#
# 注意：不用 project-list（单独使用实测无效，cgit 1.2.3 "No repositories found"），
# 改用 repo.url/repo.path 显式清单 —— 这是可靠的白名单实现。
#
# 用法（在能访问 gerrit_git 卷的容器/宿主机执行）：
#   GIT_ROOT=/var/gerrit/git bash scripts/cgit-refresh.sh
set -euo pipefail
GIT_ROOT="${GIT_ROOT:-/var/gerrit/git}"
LIST_OUT="${CGIT_PROJECTS_LIST:-/tmp/projects.conf}"
CGIT_EXCLUDE="${CGIT_EXCLUDE:-All-Projects.git All-Users.git}"

[[ -d "$GIT_ROOT" ]] || { echo "GIT_ROOT 不存在: $GIT_ROOT" >&2; exit 1; }
tmp="${LIST_OUT}.tmp.$$"
: > "$tmp"
while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  local_skip=0 ex
  for ex in $CGIT_EXCLUDE; do
    [[ "$repo" == "$ex" ]] && { local_skip=1; break; }
  done
  if [[ $local_skip -eq 0 ]]; then
    printf 'repo.url=%s\n' "$repo" >> "$tmp"
    printf 'repo.path=%s/%s\n' "$GIT_ROOT" "$repo" >> "$tmp"
  fi
done < <(find "$GIT_ROOT" -maxdepth 1 -name '*.git' -printf '%f\n' 2>/dev/null | sort)
mv "$tmp" "$LIST_OUT"
echo "✓ repo. 清单已刷新（$(grep -c '^repo.url=' "$LIST_OUT") 个业务仓）→ $LIST_OUT"
