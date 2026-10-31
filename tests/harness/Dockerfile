FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ENV DEBIAN_FRONTEND=noninteractive
# python3 要完整包：python3-minimal 不含 http/urllib，
# 而 services/router/render.py 一开头就 import http.server，minimal 会直接 ImportError
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq bats docker.io docker-compose-v2 ldap-utils tini procps iproute2 openssl dnsutils python3 \
 && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /etc/docker \
 && printf '%s\n' '{"features":{"containerd-snapshotter":false},"storage-driver":"overlay2"}' > /etc/docker/daemon.json
LABEL org.opencontainers.image.base.name="ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852"
LABEL org.opencontainers.image.title="orgflow-devops m0-test harness"
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
WORKDIR /repo
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
