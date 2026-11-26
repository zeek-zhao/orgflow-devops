# Gerrit 3.9 官方镜像薄封装（M2.4 Phase1）。
# 只加 OCI 元数据，不覆盖 ENTRYPOINT、不 COPY entrypoint.sh——
# entrypoint.sh 仍由 compose 挂载（运行时逻辑），镜像保持官方行为。
# 上游 digest 在 config/images.env 的 UPSTREAM_GERRIT 登记，与 docs/运维/镜像与供应链.md 一致。
FROM gerritcodereview/gerrit:3.9.0@sha256:25f02a983db5f2323fa2a4be7ea672a13dbe8a12cc0e0d31feaa5a348ad8df0f

LABEL org.opencontainers.image.source="https://github.com/zeek-zhao/orgflow-devops" \
      org.opencontainers.image.title="orgflow-gerrit" \
      org.opencontainers.image.description="Gerrit 3.9 code review (thin OCI metadata wrapper; entrypoint via compose mount)"
