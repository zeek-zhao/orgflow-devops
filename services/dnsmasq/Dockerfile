FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
LABEL org.opencontainers.image.title="orgflow-devops dnsmasq"
LABEL org.opencontainers.image.licenses="GPL-2.0-only"
LABEL org.opencontainers.image.licenses.note="dnsmasq is GPL-2.0; license text is shipped in the repo at licenses/GPL-2.0.txt"

# 内部 DNS：把 *.org-devops.com 解析到 Caddy 的固定 IP，
# 让容器之间（以及宿主机/局域网改 hosts 后）用域名互通。
# dnsutils 只为健康检查里的 dig，运行时不依赖它。
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dnsmasq dnsutils \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
