FROM gethomepage/homepage:v2.7.0@sha256:19c5c09184458a41b7b5915e71463a39f36cd33540f41bdbed008791b8182d5f
LABEL org.opencontainers.image.title="orgflow-devops homepage (M0 thin wrapper)"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.licenses.note="Homepage is MIT; upstream digest is locked in docs/运维/镜像与供应链.md"
# 薄封装：官方 gethomepage/homepage:v2.7.0 + 固化 4 个配置 yaml。
# 真源 config/homepage/*.yaml，由 scripts/sync-build-context.sh 同步到 build/。
# 卡片链接用 {{HOMEPAGE_VAR_GATEWAY_DOMAIN}} 占位，运行时由 compose 注入，
# 图标统一用 mdi-*（镜像自带），断网零裂图。
COPY build/settings.yaml /app/config/settings.yaml
COPY build/services.yaml /app/config/services.yaml
COPY build/bookmarks.yaml /app/config/bookmarks.yaml
COPY build/widgets.yaml   /app/config/widgets.yaml
# 修复轮 T7：favicon / custom.css / 两张 PWA 图标随镜像固化（真叠加内容）。
# 目录挂载保留（config/homepage:/app/config 便于改配置），图标同时在镜像里 → 双保险。
COPY build/favicon.ico            /app/public/favicon.ico
COPY build/custom.css             /app/config/custom.css
COPY build/android-chrome-192x192.png /app/public/android-chrome-192x192.png
COPY build/android-chrome-512x512.png /app/public/android-chrome-512x512.png
COPY build/LICENSE                /app/public/LICENSE
