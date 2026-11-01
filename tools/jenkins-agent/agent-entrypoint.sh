#!/bin/bash
# jenkins-agent 的入口包装（#45）
#
# 上游 jenkins/ssh-agent 的 entrypoint 是 setup-sshd，它靠环境变量
# JENKINS_AGENT_SSH_PUBKEY 写 authorized_keys。
#
# 这里不从 .env 传那个变量，而是从挂进来的 secrets/agent_ssh_key.pub 读：
#   - deploy.sh 有「已有 .env 就绝不修改」的约定（改 .env 会让「用户手填的密码
#     被覆盖」这类事故无从追查），所以不能为了塞一个公钥去动它；
#   - 公钥本来就和私钥是一对，放在同一个目录里由 scripts/gen-agent-key.sh
#     一起生成，比分散在 .env 里更难搞错。
set -euo pipefail

PUBKEY_FILE="${AGENT_SSH_PUBKEY_FILE:-/run/secrets/agent_ssh_pub}"

if [ -z "${JENKINS_AGENT_SSH_PUBKEY:-}" ]; then
    if [ -r "$PUBKEY_FILE" ]; then
        JENKINS_AGENT_SSH_PUBKEY="$(cat "$PUBKEY_FILE")"
        export JENKINS_AGENT_SSH_PUBKEY
    fi
fi

if [ -z "${JENKINS_AGENT_SSH_PUBKEY:-}" ]; then
    echo "缺少 agent 公钥：$PUBKEY_FILE 不存在或为空。" >&2
    echo "先跑一次 scripts/gen-agent-key.sh（deploy.sh 会自动调用）。" >&2
    exit 1
fi

# 把宿主 docker.sock 的 gid 变成 jenkins 的**附加组**（2026-11-01 真机验收）。
#
# ★ 为什么 compose 的 group_add 不够：它只给容器的 PID 1 加附加组，而 sshd 给
#   登录会话调 initgroups()，会按 /etc/group **重置**附加组。结果同一个容器里：
#       docker exec -u jenkins ... docker info   → 通（exec 继承 OCI 的 AdditionalGids）
#       ssh jenkins@jenkins-agent 'docker info'  → permission denied（只有 1000）
#   也就是说「用 docker exec 做的端到端检查」是**假阳性**，真机上 job 照样挂，
#   而且报错还是那句「找不到网络 orgflow」。只有改 /etc/group 本身，
#   initgroups() 才会把这个 gid 带上。
DOCKER_GID="${DOCKER_GID:-}"
if [ -n "$DOCKER_GID" ] && [ "$DOCKER_GID" != "0" ]; then
    current_gid="$(getent group docker | cut -d: -f3 || true)"
    if [ -z "$current_gid" ]; then
        # -o：允许与镜像里已有的组共用 gid（Debian 镜像里 998 常常已经叫别的名字）
        groupadd -o -g "$DOCKER_GID" docker 2>/dev/null || true
    elif [ "$current_gid" != "$DOCKER_GID" ]; then
        groupmod -o -g "$DOCKER_GID" docker 2>/dev/null || true
    fi
    if getent group docker >/dev/null 2>&1; then
        usermod -aG docker jenkins
    else
        # 兜底：镜像里 shadow 工具不可用时，按 gid 找现有组名
        existing="$(getent group "$DOCKER_GID" | head -1 | cut -d: -f1 || true)"
        if [ -n "$existing" ]; then
            usermod -aG "$existing" jenkins
        else
            echo "警告：无法把 gid $DOCKER_GID 加进 jenkins 的组，job 里的 docker 会 permission denied" >&2
        fi
    fi
    echo "jenkins 的附加组：$(id -Gn jenkins)"
fi

exec setup-sshd "$@"
