#!/bin/sh
# registry:2 入口（M2.2）：运行时把 REGISTRY_USER / REGISTRY_PASSWORD 渲染成 htpasswd 到卷内
# /auth/htpasswd（600，属主由镜像 registry 用户决定），再执行官方 registry 二进制。
# 凭据只经环境变量注入，不入库、不进文档、不经 git；密码用 bcrypt（-B）存储。
set -eu

AUTH_DIR=/auth
HTPASSWD="$AUTH_DIR/htpasswd"
USER="${REGISTRY_USER:-admin}"
PASS="${REGISTRY_PASSWORD:-change-me}"

mkdir -p "$AUTH_DIR"

# -B bcrypt / -b batch（从参数读，不交互）。首次创建需 -c，否则 htpasswd 报
# "cannot modify file; use -c to create it" 退出（set -e 下会让容器启动失败）。
# 若已有同名用户先删除；文件存在与否决定 -c。保证幂等且首次可起。
if [ -f "$HTPASSWD" ] && grep -q "^${USER}:" "$HTPASSWD" 2>/dev/null; then
  htpasswd -D -b "$HTPASSWD" "$USER" >/dev/null 2>&1 || true
fi
if [ -f "$HTPASSWD" ]; then
  htpasswd -B -b "$HTPASSWD" "$USER" "$PASS" >/dev/null 2>&1
else
  htpasswd -B -b -c "$HTPASSWD" "$USER" "$PASS" >/dev/null 2>&1
fi
chmod 600 "$HTPASSWD" 2>/dev/null || true

echo "[registry] htpasswd ready for user=$USER (bcrypt)" >&2

# 官方 registry:2 镜像的入口二进制是 /bin/registry，配置走环境变量 REGISTRY_*。
exec /bin/registry serve /etc/docker/registry/config.yml
