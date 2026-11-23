FROM ubuntu:24.04@sha256:9a04f13b3f80ef056361e30868593b1cfd2279fe19e4081cb93a90bf56819d6a
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates bash && rm -rf /var/lib/apt/lists/*
COPY gen-ca.sh /usr/local/bin/gen-ca.sh
RUN chmod +x /usr/local/bin/gen-ca.sh
ENTRYPOINT ["/usr/local/bin/gen-ca.sh"]
