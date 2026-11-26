#!/bin/sh
# registry:2 入口（M2.2 + M2.3 收口 P2-4）：运行时把管理员与 CI 两个账号渲染成 htpasswd
# 到卷内 /auth/htpasswd（600，属主由镜像 registry 用户决定），再执行官方 registry 二进制。
# 凭据只经环境变量注入，不入库、不进文档、不经 git；密码用 bcrypt（-B）存储。
# M2.3 前只有管理员一个账号、CI 直接复用 admin（最小权限未落地）；收口后 CI 用独立账号，
# 管理员账号保留供运维 push，两者在 htpasswd 中各占一行。
set -eu

AUTH_DIR=/auth
HTPASSWD="$AUTH_DIR/htpasswd"

mkdir -p "$AUTH_DIR"

# 幂等渲染单个账号：同名先删再追加；文件不存在时首行用 -c 创建，否则追加。
render_user() {
  u="$1"
  p="$2"
  [ -n "$u" ] && [ -n "$p" ] || return 0
  if grep -q "^${u}:" "$HTPASSWD" 2>/dev/null; then
    htpasswd -D -b "$HTPASSWD" "$u" >/dev/null 2>&1 || true
  fi
  if [ -f "$HTPASSWD" ]; then
    htpasswd -B -b "$HTPASSWD" "$u" "$p" >/dev/null 2>&1
  else
    htpasswd -B -b -c "$HTPASSWD" "$u" "$p" >/dev/null 2>&1
  fi
  echo "[registry] htpasswd ready for user=$u (bcrypt)" >&2
}

# 管理员账号（运维用）。
render_user "${REGISTRY_USER:-admin}" "${REGISTRY_PASSWORD:-change-me}"
# M2.3 收口 P2-4：CI 独立账号（buildkit push + REST 校验）。未配置时不渲染，
# 保持与旧部署兼容（旧部署 CI 仍走 admin，升级后 .env 注入即切换）。
if [ -n "${REGISTRY_CI_USER:-}" ] && [ -n "${REGISTRY_CI_PASSWORD:-}" ]; then
  render_user "$REGISTRY_CI_USER" "$REGISTRY_CI_PASSWORD"
fi
chmod 600 "$HTPASSWD" 2>/dev/null || true

# 官方 registry:2 镜像的入口二进制是 /bin/registry，配置走环境变量 REGISTRY_*。
exec /bin/registry serve /etc/docker/registry/config.yml
