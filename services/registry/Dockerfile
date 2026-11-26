# registry:2 薄封装：官方基底（digest 占位 0000…，CI 构建前 sed 注入 CI 实拉的真实 digest）
# + apache2-utils 提供 htpasswd（entrypoint 运行时生成基础鉴权文件）。
# 上游 digest 真值由 CI（mirror-m2.yml）docker pull registry:2 取 RepoDigests 产出，
# 回填 config/images.env 的 UPSTREAM_REGISTRY 与 docs/运维/镜像与供应链.md 登记表；
# 本文件保留占位以满足「FROM@sha256」门禁，image-hash.sh 口径基于本文件文本，稳定可控。
# CI 构建推 GHCR m2-registry:ctx-<12>，国内经 ghcr.nju.edu.cn 代理拉取。
FROM registry:2@sha256:0000000000000000000000000000000000000000000000000000000000000000

RUN apk add --no-cache apache2-utils \
    && rm -rf /var/cache/apk/*

COPY entrypoint.sh /usr/local/bin/orgflow-registry-entrypoint.sh
RUN chmod +x /usr/local/bin/orgflow-registry-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/orgflow-registry-entrypoint.sh"]
