# cgit（M2.1 自建）：ubuntu:24.04 + cgit/fcgiwrap/nginx-light，只读挂载 Gerrit 裸库。
# 按文档 §M2.1：user 1000:1000（须与 Gerrit 容器 uid 对齐，否则读不到裸库），
# 上游 ubuntu:24.04 @sha256 钉死；镜像由 CI 出 ctx-<12> 内容 tag（image-hash.sh）。
# 改本文件或 cgitrc/entrypoint 后必须跑 make images-hash 同步 lock/images.env/compose/tag 四处。
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

LABEL org.opencontainers.image.title="orgflow-devops cgit (M2.1)"
LABEL org.opencontainers.image.description="cgit read-only web frontend for Gerrit bare repos"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      cgit fcgiwrap nginx-light ca-certificates spawn-fcgi \
 && rm -rf /var/lib/apt/lists/*

# nginx 前台运行配置：所有请求转给 cgit fcgiwrap，监听容器内 80。
COPY nginx-cgit.conf /etc/nginx/sites-available/cgit.conf
RUN ln -sf /etc/nginx/sites-available/cgit.conf /etc/nginx/sites-enabled/cgit.conf \
 && rm -f /etc/nginx/sites-enabled/default

# cgit 配置真源（COPY 进镜像；projects.list 由 entrypoint 启动时生成）。
COPY cgitrc /etc/cgitrc
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# uid 1000 对齐 Gerrit（文档硬约束：别用 root 跑 cgit）。
RUN useradd -u 1000 -m -s /usr/sbin/nologin cgit || true \
 && mkdir -p /var/lib/nginx/body /var/cache/nginx /tmp \
 && chown -R 1000:1000 /var/lib/nginx /var/cache/nginx /var/log/nginx /tmp

EXPOSE 80
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
