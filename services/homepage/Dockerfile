FROM ubuntu:24.04@sha256:9a04f13b3f80ef056361e30868593b1cfd2279fe19e4081cb93a90bf56819d6a
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY server.py /usr/local/bin/server.py
COPY config/ /etc/homepage/
EXPOSE 3000
CMD ["python3", "/usr/local/bin/server.py"]
