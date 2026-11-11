FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
LABEL org.opencontainers.image.title="orgflow-devops jjb"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.licenses.note="jenkins-job-builder is Apache-2.0; nothing copyleft is added"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages "setuptools<81" "jenkins-job-builder==6.5.0"
