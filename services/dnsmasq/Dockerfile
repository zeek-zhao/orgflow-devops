FROM ubuntu:24.04@sha256:9a04f13b3f80ef056361e30868593b1cfd2279fe19e4081cb93a90bf56819d6a
RUN apt-get update && apt-get install -y --no-install-recommends dnsmasq dnsutils ca-certificates && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 53/udp 5353/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
