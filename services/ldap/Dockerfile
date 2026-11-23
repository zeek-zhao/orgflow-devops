FROM ubuntu:24.04@sha256:9a04f13b3f80ef056361e30868593b1cfd2279fe19e4081cb93a90bf56819d6a
RUN DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends slapd ldap-utils python3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bootstrap.ldif.tmpl /etc/ldap/bootstrap.ldif.tmpl
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 389
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
