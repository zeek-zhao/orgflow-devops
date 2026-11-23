FROM ubuntu:24.04@sha256:9a04f13b3f80ef056361e30868593b1cfd2279fe19e4081cb93a90bf56819d6a
# 基础工具 + 官方 cloudsmith 源安装 caddy 本体（此前漏装导致 exec: caddy: not found）
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates openssl bash debian-keyring gpg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg \
    && chmod a+r /etc/apt/keyrings/caddy-stable-archive-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
       > /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends caddy \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 80 443 2019
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
