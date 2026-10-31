#!/usr/bin/env bash
# 生成 jenkins-agent 的 SSH 密钥对（#45）。
#
# 产物（都在 secrets/ 下，整个目录已 gitignore）：
#   secrets/agent_ssh_key      私钥 → deploy.sh/harness 读出并 export 成
#                              JENKINS_AGENT_SSH_PRIVATE_KEY，JCasC 用 directEntry 引用
#   secrets/agent_ssh_key.pub  公钥 → 挂进 agent 容器当 authorized_keys
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
