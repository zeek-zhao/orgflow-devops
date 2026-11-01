#!/usr/bin/env bash
# 生成 jenkins-agent 的 SSH 密钥对（#45）。
#
# 产物（都在 secrets/ 下，整个目录已 gitignore）：
#   secrets/agent_ssh_key      私钥 → deploy.sh/harness 读出并 export 成
#                              JENKINS_AGENT_SSH_PRIVATE_KEY，JCasC 用 directEntry 引用
#   secrets/agent_ssh_key.pub  公钥 → 挂进 agent 容器当 authorized_keys
#   secrets/agent_host_key     agent 容器 sshd 的 host key → 挂到
#                              /etc/ssh/ssh_host_ed25519_key，让 host key 跨重建稳定
#   secrets/agent_host_key.pub 对应公钥 → export 成 JENKINS_AGENT_HOST_KEY，
#                              JCasC 用 manuallyProvidedKeyVerificationStrategy 声明
#
# 为什么不把公钥写进 .env：
#   deploy.sh 有「已有 .env 就绝不修改」的约定（否则「用户手填的密码被覆盖」
#   这类事故无从追查），所以不能为了一个公钥去动它。公钥私钥本来就该放一起。
#
# 幂等：密钥已存在就复用。**绝不覆盖** —— 覆盖等于所有 agent 立刻连不上，
# 而且 Jenkins 里那份凭据还指着旧私钥。
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_DIR="secrets"
PRIVATE_KEY="$KEY_DIR/agent_ssh_key"
PUBLIC_KEY="$PRIVATE_KEY.pub"

# umask 077：密钥文件默认就是 0600，避免先生成再 chmod 的空档
umask 077
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [ ! -s "$PRIVATE_KEY" ]; then
    # ed25519：比 RSA 短、握手快，OpenSSH 6.5+ 默认支持。
    # -N '' 是「无口令」——Jenkins 用凭据里的私钥自动登录，没有地方输入口令。
    ssh-keygen -t ed25519 -N '' -C 'jenkins-agent@orgflow-devops' -f "$PRIVATE_KEY" >/dev/null
    echo "已生成 agent 密钥对：$PRIVATE_KEY"
else
    echo "复用已有 agent 密钥：$PRIVATE_KEY"
fi
chmod 600 "$PRIVATE_KEY"

# 公钥缺失（只删了 .pub）时从私钥重新导出，避免整套重建
if [ ! -s "$PUBLIC_KEY" ]; then
    ssh-keygen -y -f "$PRIVATE_KEY" > "$PUBLIC_KEY"
    chmod 644 "$PUBLIC_KEY"
fi

# agent 容器的 **sshd host key**（2026-11-01 真机验收踩到）。
#
# 为什么要固定它：agent 容器的 /etc/ssh 不持久化，每次重建 `ssh-keygen -A` 都
# 生成新的 host key。而 JCasC 用的是 manuallyTrustedKeyVerificationStrategy ——
# 它记住第一次见到的 key，key 一变就要人点「Trust SSH Host Key」，节点直接离线，
# 三个 pipeline job 全部 pending。真机上表现为 `Connection closed ... [preauth]`，
# 完全看不出是 host key 的问题。
#
# 所以把 host key 也做成 secrets/ 里的受管产物，挂进容器覆盖
# /etc/ssh/ssh_host_ed25519_key（`ssh-keygen -A` 见到已存在就跳过 ed25519），
# JCasC 再用 manuallyProvidedKeyVerificationStrategy 显式声明期望的 key。
# 这样 host key 跨重建稳定，也不需要任何人去点信任。
HOST_KEY="$KEY_DIR/agent_host_key"
HOST_PUB="$HOST_KEY.pub"

if [ ! -s "$HOST_KEY" ]; then
    ssh-keygen -t ed25519 -N '' -C 'jenkins-agent-host@orgflow-devops' -f "$HOST_KEY" >/dev/null
    echo "已生成 agent host key：$HOST_KEY"
else
    echo "复用已有 agent host key：$HOST_KEY"
fi
chmod 600 "$HOST_KEY"

if [ ! -s "$HOST_PUB" ]; then
    ssh-keygen -y -f "$HOST_KEY" > "$HOST_PUB"
    chmod 644 "$HOST_PUB"
fi

