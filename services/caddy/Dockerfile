FROM caddy:2@sha256:36c24ad91a7ff7bc4c87fe22bfa8df3c4b18da0773d73fc12ee2c52b98c0bb7e
LABEL org.opencontainers.image.title="orgflow-devops caddy (M0 thin wrapper)"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.licenses.note="Caddy is Apache-2.0; upstream digest is locked in docs/运维/镜像与供应链.md"
# 薄封装：官方 caddy:2 + 固化本仓库的站点配置模板。
# 配置真源 config/Caddyfile，由 scripts/sync-build-context.sh 同步到 build/。
# Caddyfile 里域名用 {$GATEWAY_DOMAIN} 占位符，运行时由 compose 的 environment 注入，
# 因此镜像里没有任何写死域名（check-domain.sh 门禁）。
COPY build/Caddyfile /etc/caddy/Caddyfile
