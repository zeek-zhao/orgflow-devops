# Jenkins agent：给 pipeline job 提供 docker 能力（#45）
#
# 为什么单独一个容器，而不是把 docker 塞进 controller：
#   - controller 挂 /var/run/docker.sock 等于把宿主 root 交给 Jenkins 主进程，
#     而 controller 是唯一跑 JCasC、拿全部凭据的地方，权限叠加起来最危险；
#   - job 里 docker 构建产生的文件属主是 root，直接污染 controller 的 workspace；
#   - 独立 agent 可以随时重建，controller 镜像保持干净。
#
# 底座 jenkins/ssh-agent:jdk21 已核实是 Debian（用 apt-get），用户 jenkins(1000)，
# JENKINS_AGENT_HOME=/home/jenkins，AGENT_WORKDIR=/home/jenkins/agent，
# java 在 /opt/java/openjdk/bin/java —— 这几项直接决定 JCasC 里 node 的写法。
FROM jenkins/ssh-agent:jdk21@sha256:a62ab1b4b51fbd77a12ba6382d5f550d105a7ece1cad3b7be49e1df56766d364

LABEL org.opencontainers.image.base.name="jenkins/ssh-agent:jdk21@sha256:a62ab1b4b51fbd77a12ba6382d5f550d105a7ece1cad3b7be49e1df56766d364"
LABEL org.opencontainers.image.title="orgflow-devops jenkins-agent"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.licenses.note="Built on jenkins/ssh-agent (MIT); only the Docker CLI (Apache-2.0) is added"

# 只装 docker CLI，不装 daemon。
# daemon 用宿主机的（挂 /var/run/docker.sock 复用），装 docker.io 会白带一个
# 永远不启动的 dockerd，镜像大 100MB 而且会让人误以为容器里能独立跑 docker。
ARG DOCKER_CLI_VERSION=27.5.1

# compose 插件：deploy.sh / backup.sh 都是 `docker compose ...`，
# agent 里没有它，deploy-service / verify-<svc> 这类真跑 deploy.sh 的 job
# 会死在「docker: 'compose' is not a docker command」（真机 verify-ldap #2）。
# 版本与两个架构的 sha256 从 download.docker.com 的 Packages 索引取值后钉死，
# 防的是「构建日不同、插件版本漂移」——和上面 DOCKER_CLI_VERSION 同一套路。
ARG COMPOSE_PLUGIN_VERSION=5.7.0-1~debian.13~trixie
ARG COMPOSE_PLUGIN_SHA256_AMD64=2f30b57fab676874cf598d8a2960b230d5e6cd2d3f3c027dec87865589ec1e1f
ARG COMPOSE_PLUGIN_SHA256_ARM64=4f21245314ea6355398580c875f063dbebce37cf83912dcd132909551886fdc1

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl python3 \
 && rm -rf /var/lib/apt/lists/* \
 && arch="$(dpkg --print-architecture)" \
 && case "$arch" in \
        amd64) dockerarch=x86_64 ;; \
        arm64) dockerarch=aarch64 ;; \
        *) echo "不支持的架构: $arch" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${dockerarch}/docker-${DOCKER_CLI_VERSION}.tgz" \
    | tar -xz --strip-components=1 -C /usr/local/bin docker/docker \
 && docker --version

# compose 插件按 debian 源的 deb 安装（cli-plugins 目录归 deb 管，升级省心）。
# codename 从 os-release 取：底座换发行版时这里不用跟着改。
RUN . /etc/os-release \
 && arch="$(dpkg --print-architecture)" \
 && case "$arch" in \
        amd64) want_sha="$COMPOSE_PLUGIN_SHA256_AMD64" ;; \
        arm64) want_sha="$COMPOSE_PLUGIN_SHA256_ARM64" ;; \
        *) echo "不支持的架构: $arch" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/compose.deb \
      "https://download.docker.com/linux/debian/dists/${VERSION_CODENAME}/pool/stable/${arch}/docker-compose-plugin_${COMPOSE_PLUGIN_VERSION}_${arch}.deb" \
 && echo "${want_sha}  /tmp/compose.deb" | sha256sum -c - \
 && dpkg -i /tmp/compose.deb \
 && rm -f /tmp/compose.deb \
 && docker compose version

# 公钥从挂进来的文件读，不从 .env 读（理由见 agent-entrypoint.sh 文件头）
COPY agent-entrypoint.sh /usr/local/bin/agent-entrypoint.sh
RUN chmod +x /usr/local/bin/agent-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/agent-entrypoint.sh"]

# ★ 不要在这里切回 USER jenkins。上游 ssh-agent 镜像就是以 root 跑 setup-sshd 的
#   （sshd 绑 22 这个特权端口需要 root），切走会直接起不来。
#
# ★ 但「sshd 以 root 跑」**不等于**「job 里的命令以 root 跑」。镜像里
#   `PermitRootLogin no`，Jenkins 用 jenkins(1000) 登录，所以 job 里的 docker
#   命令是 uid 1000 在跑。因此 /var/run/docker.sock（root:<docker 组> 0660）
#   必须让这个用户拿到 —— 由 agent-entrypoint.sh 在启动时把 socket 的 gid 写进
#   /etc/group 并把 jenkins 加进去（2026-11-01 真机验收踩到）。
#
#   ★ 光靠 compose 的 group_add 不行：它只影响容器的 PID 1，而 sshd 给登录会话
#     调 initgroups() 会按 /etc/group 重置附加组。这就是为什么
#     `docker exec -u jenkins docker info` 通、真实 SSH 会话却 permission denied。
