FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY render.py /app/render.py
CMD ["python3", "/app/render.py", "--routes", "/app/config/routes.yaml", "--out", "/app/out/Caddyfile", "--watch"]
