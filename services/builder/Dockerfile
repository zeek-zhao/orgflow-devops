# BuildKit builder（M2.3）：rootless buildkitd，供 Jenkins agent 经 TCP 提交构建。
# 上游 moby/buildkit:v0.16.0-rootless（amd64 manifest digest 钉死，2026-11-26 查 Docker Hub）。
# 薄封装仅补 buildkitd.toml（声明内网 registry 为 http/insecure）；不 add 用户/不改入口语义。
#
# 为什么 rootless + no-process-sandbox：controller 不跑构建、agent 无 docker.sock，
# 构建统一收敛到这个独立容器；rootless 降低逃逸面，no-process-sandbox 适配受限内核。
# 上游 digest 真值同步在 config/images.env（UPSTREAM_BUILDER）与 tests/images.lock。
ARG BASE_DIGEST=sha256:ae19c93689d1a9f510c656c83a68f41a9d97a87dddbc285af078fc7522074111
FROM moby/buildkit:v0.16.0-rootless@${BASE_DIGEST}

LABEL org.opencontainers.image.source="https://github.com/zeek-zhao/orgflow-devops"
LABEL org.opencontainers.image.base.name="moby/buildkit:v0.16.0-rootless@sha256:ae19c93689d1a9f510c656c83a68f41a9d97a87dddbc285af078fc7522074111"
LABEL org.opencontainers.image.title="orgflow-devops m2-builder (rootless buildkitd)"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.description="rootless BuildKit daemon for Jenkins CI builds"

USER root
COPY buildkitd.toml /etc/buildkit/buildkitd.toml
RUN chmod 644 /etc/buildkit/buildkitd.toml
# 官方 rootless 镜像 Config.User=buildkit 但 /etc/passwd 无该用户名条目（用数字 UID）。
# 若写 USER buildkit，docker 启动时会解析用户名失败（unable to find user buildkit）；
# 必须用数字 UID 1000（与上游一致），rootlesskit entrypoint 再做 user namespace 映射。
# 实测 USER 1000 + command 覆盖参数可正常起 buildkitd 并暴露 linux/amd64 worker。
USER 1000
