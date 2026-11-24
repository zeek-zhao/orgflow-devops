FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
LABEL org.opencontainers.image.title="orgflow-devops router (M0 minimal)"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.licenses.note="Project code is Apache-2.0; nothing copyleft is added"
# 路由注册 API：routes.yaml → 校验 → 渲染 → Caddy admin /load。
# 零第三方依赖（不装 PyYAML），server.py 手写极简 YAML 解析，和 main 的 render.py 同思路。
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY server.py /app/server.py
EXPOSE 8080
CMD ["python3", "/app/server.py"]
