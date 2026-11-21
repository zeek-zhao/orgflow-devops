# 文档站镜像：mkdocs-material 官方镜像 + 本仓库的 mkdocs.yml 与文档源
#
# 为什么没用官方镜像直接跑：官方镜像的工作目录里没有我们的 mkdocs.yml，
# 而站点导航（nav）与主题配置都要入库、可 review，所以构建时烤进镜像。
# 文档内容本身仍然在启动时从镜像里构建进 docs_site 卷 —— 改文档要重建镜像或
# 用 `make docs-site`（挂载本地 docs/ 重建），见 docs/60-测试与运维/常用命令.md。
FROM squidfunk/mkdocs-material:9.8.2@sha256:fd13d78a4b1da637405c0336c9f0a4e0594b59271df106bd9cd64cae56cd1f38

WORKDIR /work
COPY mkdocs.yml /work/mkdocs.yml
COPY docs /work/docs
COPY config/orgflow.yml /work/config/orgflow.yml

# 构建产物目录由 compose 挂到卷上；这里先建好，保证以 root 运行时也有写权限
RUN mkdir -p /site
