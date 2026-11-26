#!/usr/bin/env bash
# 生成 jenkins-agent 的 SSH 密钥对与 sshd host key（M1，幂等）。
#
# 产物（都在 secrets/ 下，整个目录已 gitignore，不进仓库、不进 .env）：
#   secrets/agent_ssh_key      私钥 → JENKINS_AGENT_SSH_KEY（宿主 export，JCasC directEntry）
#   secrets/agent_ssh_key.pub  公钥 → 挂进 agent 容器 /run/secrets/agent_ssh_pub（authorized_keys）
#   secrets/agent_host_key     sshd host key → 挂到 /etc/ssh/ssh_host_ed25519_key（跨重建稳定）
#   secrets/agent_host_key.pub 对应公钥 → JENKINS_AGENT_HOST_KEY（manuallyProvided 校验值）
#
# 幂等：密钥已存在绝不覆盖（覆盖等于 agent 立刻脱机、Jenkins 凭据还指旧私钥）。
# 顺手把挂载的共享库 chmod -R a+rX，保证容器内普通用户 jenkins 可读不可写。
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_DIR="secrets"
PRIVATE_KEY="$KEY_DIR/agent_ssh_key"
PUBLIC_KEY="$PRIVATE_KEY.pub"
HOST_KEY="$KEY_DIR/agent_host_key"
HOST_PUB="$HOST_KEY.pub"

umask 077
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

gen_if_missing() {
    local key="$1" comment="$2" pub="$3"
    if [ ! -s "$key" ]; then
        ssh-keygen -t ed25519 -N '' -C "$comment" -f "$key" >/dev/null
        echo "已生成 $key"
    else
        echo "复用已有 $key"
    fi
    chmod 600 "$key"
    if [ ! -s "$pub" ]; then
        ssh-keygen -y -f "$key" > "$pub"
        chmod 644 "$pub"
    fi
}

gen_if_missing "$PRIVATE_KEY" 'jenkins-agent@orgflow-devops' "$PUBLIC_KEY"
gen_if_missing "$HOST_KEY" 'jenkins-agent-host@orgflow-devops' "$HOST_PUB"

# M2.3：Gerrit CI 账号 ci-bot 的 SSH key（gerrit-trigger 收事件 + review 回写 Verified）。
# 首次由本脚本生成后须把公钥 POST 到 Gerrit /a/accounts/ci-bot/sshkeys（text/plain raw），
# 之后幂等复用——覆盖会让 Gerrit 侧公钥失配、CI 立刻无法推流/回写。
CI_KEY="$KEY_DIR/gerrit_ci_ssh_key"
CI_PUB="$CI_KEY.pub"
gen_if_missing "$CI_KEY" 'ci-bot@orgflow-devops' "$CI_PUB"
echo "注意：首次生成后须把 $CI_PUB 注册到 Gerrit 账号 ci-bot（见执行日志 M2.3.0）"

# 共享库挂载目录：宿主属主挂进容器后 jenkins 只靠权限位读 → 755/644，不要求写权限。
if [ -d ci/shared-library ]; then
    chmod -R a+rX ci/shared-library
    echo "✓ ci/shared-library 已 chmod -R a+rX"
fi

# 输出供宿主 export 的提示（不写入任何文件，避免敏感值落盘到仓库）。
echo "--- 启动前在宿主 export（本脚本不自动写 .env）---"
echo "export JENKINS_AGENT_SSH_KEY=\"\$(cat $PRIVATE_KEY)\""
echo "export JENKINS_AGENT_HOST_KEY=\"\$(awk '{print \$1\" \"\$2}' $HOST_PUB)\""
