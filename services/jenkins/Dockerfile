# Jenkins 自建镜像：JDK21 + 默认插件清单（#90 / REQ-M0-B1）
#
# 为什么不能直接用上游镜像：上游 jenkins/jenkins 一个插件都不带，pipeline job
# 起不来（没有 workflow-aggregator）、git 拉不了仓库、SSH agent 连不上、
# JCasC 不生效、LDAP 登录没有对应插件。装机即可用，不靠人工在 UI 里点装。
#
# 插件装到 /usr/share/jenkins/ref/plugins，镜像自带的 entrypoint 首次启动会把它
# 复制进 $JENKINS_HOME/plugins，所以卷里已有数据也能补上。
#
# 8 个插件各自的作用：
#   workflow-aggregator    三个 job 都是 pipeline，没有它 job 定义都解析不了
#   git                    拉共享库 orgflow-shared 与业务仓库（带 git-client）
#   credentials            JCasC 声明的凭据要存在这里
#   credentials-binding    pipeline 里 withCredentials 需要它
#   plain-credentials      ldap-admin-password 等 Secret text 类型凭据
#   ssh-slaves             SSH 接入 agent 容器，node('orgflow-docker') 靠它
#   ldap                   #90 新增：LDAP 登录/组解析（配合 config/jenkins.yaml）
#   configuration-as-code  让 config/jenkins.yaml 生效
#
# 底座按 digest 钉死：tag 会漂，digest 不会。213/214 拉不到 Docker Hub，
# 这一份只在能出网的 CI runner 上构建后推 GHCR，再由 docker-compose.ghcr.yml
# 以 digest 锁定；USE_GHCR=1 时 up/deploy 必须 --no-build（见 Makefile）。
#
# plugins.txt 刻意保持纯列表（不写注释、不钉版本）：
#   - jenkins-plugin-cli 对 `#` 注释的容忍度不稳，宁可把理由写在这里；
#   - 可复现性由 GHCR 上的镜像 digest 保证，不是插件版本号。
FROM jenkins/jenkins:lts-jdk21@sha256:74401de6a6f92e1afe1b02d1c8e3d0c33f263bfb5275dd8813f9150355f2367b

LABEL org.opencontainers.image.base.name="jenkins/jenkins:lts-jdk21@sha256:74401de6a6f92e1afe1b02d1c8e3d0c33f263bfb5275dd8813f9150355f2367b"
LABEL org.opencontainers.image.title="orgflow-devops jenkins"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.licenses.note="Jenkins core and the bundled plugins are MIT-licensed"
LABEL org.opencontainers.image.description="Jenkins controller with the default plugin set (workflow-aggregator, git, credentials, ldap, configuration-as-code)"

# USER root 是必需的：上游镜像末尾已经切回 jenkins 用户，
# 而 /usr/share/jenkins/ref 只有 root 可写，不切会 EACCES。
USER root
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
USER jenkins
