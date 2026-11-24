#!/usr/bin/env bash
# sync-build-context.sh —— 把 config/ 真源 + 各服务叠加文件同步到构建上下文 build/。
#
# 为什么这一步：
#   AC-20 / 修复轮 T2 要求「仅 checkout 本分支，6 个镜像全部构建成功」，
#   且 Dockerfile 只能 COPY 自己目录内的文件（buildx 上下文自包含）。
#   配置真源只允许一份（config/），不能在每个 services/<svc>/ 下手抄副本。
#   构建前用本脚本单向同步 config/ → services/<svc>/build/：真源仍是 config/，
#   build/ 是生成物（.gitignore 忽略，不入库）。
#
# 用法：bash scripts/sync-build-context.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

sync() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "  $src -> $dst"
}

echo "== 同步镜像构建上下文（config/ + services/ 为真源）=="

# caddy：站点配置模板 + 健康检查 + license
sync config/Caddyfile services/caddy/build/Caddyfile
sync services/caddy/health.sh services/caddy/build/health.sh
sync licenses/Apache-2.0.txt services/caddy/build/LICENSE

# ldap：初始用户 LDIF（50 基础账号 + 51 Jenkins 账号组）+ 健康检查 + license
sync config/ldap/50-users.ldif services/ldap/build/50-users.ldif
sync config/ldap/51-jenkins.ldif services/ldap/build/51-jenkins.ldif
sync services/ldap/ldap-health.sh services/ldap/build/ldap-health.sh
sync licenses/GPL-2.0-only.txt services/ldap/build/LICENSE

# ldapadmin：健康检查 + favicon + license
sync services/ldapadmin/health.sh services/ldapadmin/build/health.sh
sync config/homepage/favicon.ico services/ldapadmin/build/favicon.ico
sync licenses/GPL-2.0-only.txt services/ldapadmin/build/LICENSE

# homepage：4 yaml + custom.css + favicon + 两张 PWA 图标 + license
mkdir -p services/homepage/build
for y in settings services bookmarks widgets; do
  sync "config/homepage/$y.yaml" "services/homepage/build/$y.yaml"
done
sync config/homepage/custom.css services/homepage/build/custom.css
sync config/homepage/favicon.ico services/homepage/build/favicon.ico
sync config/homepage/android-chrome-192x192.png services/homepage/build/android-chrome-192x192.png
sync config/homepage/android-chrome-512x512.png services/homepage/build/android-chrome-512x512.png
sync licenses/MIT.txt services/homepage/build/LICENSE

echo "✓ 构建上下文已同步（build/ 为生成物，勿手改）"
