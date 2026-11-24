#!/usr/bin/env bash
# sync-build-context.sh —— 把 config/ 真源同步到各服务的自包含构建上下文 build/。
#
# 为什么要这一步：
#   AC-20 要求「仅 checkout 本分支，7 个镜像全部构建成功，不依赖其他分支」，
#   且 CI 的 buildx 上下文必须自包含（Dockerfile 只能 COPY 自己目录内的文件）。
#   但配置真源只允许有一份（config/），不能在每个 services/<svc>/ 下手抄副本。
#   于是构建前用本脚本把 config/ → services/<svc>/build/ 单向同步：
#   真源仍是 config/，build/ 是生成物（.gitignore 忽略，不入库）。
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

echo "== 同步镜像构建上下文（config/ 为真源）=="

# caddy：站点配置模板固化进薄封装镜像（域名用 {$GATEWAY_DOMAIN} 占位，运行时注入）
sync config/Caddyfile services/caddy/build/Caddyfile

# ldap：初始用户 LDIF 固化进薄封装镜像的 bootstrap 目录
sync config/ldap/50-users.ldif services/ldap/build/50-users.ldif

# homepage：4 个 yaml 固化进薄封装镜像的 /app/config
mkdir -p services/homepage/build
for y in settings services bookmarks widgets; do
  sync "config/homepage/$y.yaml" "services/homepage/build/$y.yaml"
done

echo "✓ 构建上下文已同步（build/ 为生成物，勿手改）"
