FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
LABEL org.opencontainers.image.title="orgflow-devops router"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.licenses.note="Project code is Apache-2.0; nothing copyleft is added"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY render.py /app/render.py
# 运行期加路由要补签叶子证书；签发实现只放一份（仓根 scripts/lib），由 compose 挂进来。
# 目录先建好，挂载点才不会变成「文件挂成目录」。
RUN mkdir -p /app/scripts/lib
CMD ["python3", "/app/render.py", "--routes", "/app/config/routes.yaml", "--out", "/app/out/Caddyfile", "--watch", "--ca-dir", "/app/out/ca"]
