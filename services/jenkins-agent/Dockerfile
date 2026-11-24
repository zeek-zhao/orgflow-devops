# Jenkins SSH agent（M1）：探测类 Job 的执行节点，无 docker.sock、普通用户 jenkins 跑会话。
#
# 基底 jenkins/ssh-agent:9.8.0-jdk21 @sha256:8fbbc58...（2026-11-25 imagetools 复核为多架构 manifest digest）。
# 该镜像基于 Debian，jenkins(1000) 普通用户、JENKINS_AGENT_HOME=/home/jenkins、
# AGENT_WORKDIR=/home/jenkins/agent、java 在 /opt/java/openjdk/bin/java（与 JCasC javaPath 一致）。
#
# ★ 不挂 docker.sock：本轮 Job 只做局域网探测，不需要 Docker 权限。
# ★ Dockerfile 末尾保持 USER root：上游 setup-sshd entrypoint 要以 root 启 sshd 绑 22；
#   "普通用户"指 SSH 登录会话用户（镜像 PermitRootLogin no → jenkins），不是容器 PID 1。
FROM jenkins/ssh-agent:9.8.0-jdk21@sha256:8fbbc589fa4257287cb9903ed1e021b90db2be2827a80e86a433d9395ca7d019

LABEL org.opencontainers.image.base.name="jenkins/ssh-agent:9.8.0-jdk21@sha256:8fbbc589fa4257287cb9903ed1e021b90db2be2827a80e86a433d9395ca7d019"
LABEL org.opencontainers.image.title="orgflow-devops m1-jenkins-agent"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.description="Jenkins SSH agent with LAN probe tools (dig/ldapsearch/curl/ping), no docker.sock"

USER root
ENV DEBIAN_FRONTEND=noninteractive TZ=Asia/Shanghai
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata curl ca-certificates jq git bash openssh-client tar coreutils \
      dnsutils ldap-utils iputils-ping netcat-openbsd \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/* \
 && /opt/java/openjdk/bin/java -version

# 入口：从挂载的 secrets 读公钥 → export JENKINS_AGENT_SSH_PUBKEY → exec 上游 setup-sshd。
COPY agent-entrypoint.sh /usr/local/bin/agent-entrypoint.sh
RUN chmod +x /usr/local/bin/agent-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/agent-entrypoint.sh"]

# ★ 不在此切回 USER jenkins（见文件头）。Job 会话由 sshd 以 jenkins 用户建立。
