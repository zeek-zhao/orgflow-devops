# certs-init 独立薄镜像（M2.4 Phase1）：一次性容器，生成内部 CA 后退出。
# compose 仍可复用 router 镜像 + 挂 gen-ca.sh；本 Dockerfile 提供可独立构建的等价薄封装。
# 上游 ubuntu digest 在 config/images.env 的 UPSTREAM_CERTS_INIT 登记。
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

LABEL org.opencontainers.image.source="https://github.com/zeek-zhao/orgflow-devops" \
      org.opencontainers.image.title="orgflow-certs-init" \
      org.opencontainers.image.description="One-shot internal CA initializer (openssl)"

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY gen-ca.sh /usr/local/bin/gen-ca.sh
RUN chmod +x /usr/local/bin/gen-ca.sh
ENTRYPOINT ["/usr/local/bin/gen-ca.sh"]
