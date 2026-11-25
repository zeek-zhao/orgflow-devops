#!/usr/bin/env bash
# cgit entrypoint（文档 §M2.1）：启动前刷新 projects.list（从 Gerrit 裸库目录扫 *.git），
# 然后拉起 spawn-fcgi(fcgiwrap) + nginx（前台）。
# projects.list 也可由 Jenkins 定时 Job（cgit-refresh）刷新；此处保证冷启即可读。
set -euo pipefail

GIT_ROOT="${GIT_ROOT:-/var/gerrit/git}"
PROJECTS_LIST="${PROJECTS_LIST:-/var/gerrit/git/projects.list}"

# Gerrit 裸库目录只读挂载，projects.list 需在可写位置；cgitrc 指向 GIT_ROOT 下，
# 若为只读则退到 /tmp（并在 cgitrc 注释说明）。默认写 /tmp，避免写只读卷失败。
LIST_OUT="${CGIT_PROJECTS_LIST:-/tmp/projects.list}"

refresh_list() {
  local tmp="${LIST_OUT}.tmp.$$"
  : > "$tmp"
  if [[ -d "$GIT_ROOT" ]]; then
    find "$GIT_ROOT" -maxdepth 1 -name '*.git' -printf '%f\n' 2>/dev/null | sort >> "$tmp" || true
  fi
  mv "$tmp" "$LIST_OUT"
}

refresh_list

# 定时刷新（每 5 分钟），与 Jenkins cgit-refresh Job 互为兜底。
( while true; do sleep 300; refresh_list; done ) &

# fcgiwrap：nginx 通过 unix socket 调 cgit.cgi；socket 放 /tmp（uid 1000 可写）。
rm -f /tmp/fcgiwrap.socket
spawn-fcgi -s /tmp/fcgiwrap.socket -M 0666 -- /usr/sbin/fcgiwrap &

# 非 root 运行：pid 文件放 /tmp（默认 /run/nginx.pid 为 root 所有，写不了）。
exec nginx -g 'daemon off; pid /tmp/nginx.pid;'
