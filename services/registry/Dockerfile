# registry:2 薄封装：官方基底通过 build-arg 注入上游 digest；默认值 = CI 实拉的真实 digest，
# 保证仓库里的 Dockerfile 直接 `docker build services/registry` 就能构建（M2.2 P2-2）。
# CI（mirror-m2.yml）用 `docker build --build-arg BASE_DIGEST=$UP` 注入当日实拉 digest，
# 不再 sed 改文件——仓库内容与 CI 构建输入一致，杜绝「绿得靠口径」。
# 上游 digest 真值同步在 config/images.env 的 UPSTREAM_REGISTRY 与 docs/运维/镜像与供应链.md。
ARG BASE_DIGEST=sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
FROM registry:2@${BASE_DIGEST}

RUN apk add --no-cache apache2-utils \
    && rm -rf /var/cache/apk/*

COPY entrypoint.sh /usr/local/bin/orgflow-registry-entrypoint.sh
RUN chmod +x /usr/local/bin/orgflow-registry-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/orgflow-registry-entrypoint.sh"]
