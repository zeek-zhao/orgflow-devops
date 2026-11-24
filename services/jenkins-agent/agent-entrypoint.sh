#!/bin/bash
# jenkins-agent 入口包装（M1）：从挂载的 secrets 读 SSH 公钥，交给上游 setup-sshd。
#
# 上游 jenkins/ssh-agent 的 entrypoint（setup-sshd）靠环境变量 JENKINS_AGENT_SSH_PUBKEY
# 写 /home/jenkins/.ssh/authorized_keys（由 root 建，需 chown jenkins）。
# 公钥不放 .env、不进仓库：由 scripts/gen-jenkins-secrets.sh 幂等生成 secrets/agent_ssh_key.pub，
# compose 挂到 /run/secrets/agent_ssh_pub，这里读入后 export。
set -euo pipefail

PUBKEY_FILE="${AGENT_SSH_PUBKEY_FILE:-/run/secrets/agent_ssh_pub}"

if [ -z "${JENKINS_AGENT_SSH_PUBKEY:-}" ] && [ -r "$PUBKEY_FILE" ]; then
    JENKINS_AGENT_SSH_PUBKEY="$(cat "$PUBKEY_FILE")"
    export JENKINS_AGENT_SSH_PUBKEY
fi

if [ -z "${JENKINS_AGENT_SSH_PUBKEY:-}" ]; then
    echo "缺少 agent 公钥：$PUBKEY_FILE 不存在或为空；先跑 scripts/gen-jenkins-secrets.sh" >&2
    exit 1
fi

# 共享库挂载目录由宿主挂入（ro），确保 jenkins 用户可读不可写：宿主侧已 chmod -R a+rX。
# 这里只做存在性提示，不改权限（ro 挂载改不动）。
if [ ! -r /opt/orgflow/shared/bin/check-lan.sh ]; then
    echo "提示：/opt/orgflow/shared/bin/check-lan.sh 不可读，共享库挂载或权限有问题" >&2
fi

exec setup-sshd "$@"
