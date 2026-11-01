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

# 只装 docker CLI，不装 daemon。
# daemon 用宿主机的（挂 /var/run/docker.sock 复用），装 docker.io 会白带一个
# 永远不启动的 dockerd，镜像大 100MB 而且会让人误以为容器里能独立跑 docker。
ARG DOCKER_CLI_VERSION=27.5.1

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
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
#   必须通过 compose 的 group_add 把 socket 的 gid 补给这个用户，否则
#   `docker network inspect` 之类的调用会 permission denied。
#   2026-11-01 真机验收就踩了这个，报错伪装成「找不到网络 orgflow」。
