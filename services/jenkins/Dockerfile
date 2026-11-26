# Jenkins controller —— M1（钉死基底 + 官方源 + 版本钉死的插件）
#
# 为什么自建：上游 jenkins/jenkins 不带任何插件，pipeline / JCasC / LDAP / SSH agent
# 四项一个都不支持，装机即可用不能靠人工点装。
#
# 版本钉死策略（M1 口径）：
#   - 基底 jenkins/jenkins:lts-jdk21 @sha256 固定（与 main 同款 digest）；
#   - plugins.txt 每行 name:version，版本来自官方 update-center.json（见 plugins.lock.md）；
#   - 安装时显式 --jenkins-update-center https://updates.jenkins.io/update-center.json，
#     运行时 compose 再注入 JENKINS_UC / JENKINS_UC_DOWNLOAD，避免镜像站点变更导致装不上。
FROM jenkins/jenkins:lts-jdk21@sha256:74401de6a6f92e1afe1b02d1c8e3d0c33f263bfb5275dd8813f9150355f2367b

LABEL org.opencontainers.image.source="https://github.com/zeek-zhao/orgflow-devops"
LABEL org.opencontainers.image.base.name="jenkins/jenkins:lts-jdk21@sha256:74401de6a6f92e1afe1b02d1c8e3d0c33f263bfb5275dd8813f9150355f2367b"
LABEL org.opencontainers.image.title="orgflow-devops m1-jenkins controller"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.description="Jenkins controller with pinned plugins (workflow-aggregator, git, ldap, configuration-as-code, job-dsl)"

# /usr/share/jenkins/ref 只有 root 可写，装插件必须切 root；装完切回 jenkins（controller 无需 root）。
USER root
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli \
      --plugin-file /usr/share/jenkins/ref/plugins.txt \
      --jenkins-update-center https://updates.jenkins.io/update-center.json
USER jenkins
