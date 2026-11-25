# 服务脚手架模板 Dockerfile —— 仅当服务无官方镜像需自建时使用。
# 硬约束：FROM 用上游 digest（在 config/images.env 登记 UPSTREAM_<SVC>），
#   内容哈希 tag 由 scripts/image-hash.sh 计算，CI 构建推 GHCR，不在源码写死版本。
ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/zeek-zhao/orgflow-devops"

RUN apk add --no-cache ca-certificates
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
