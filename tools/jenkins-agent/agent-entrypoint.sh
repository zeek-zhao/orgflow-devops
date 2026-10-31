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

exec setup-sshd "$@"
