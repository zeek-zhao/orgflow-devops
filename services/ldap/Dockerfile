FROM osixia/openldap:1.5.0@sha256:18742e9c449c9c1afe129d3f2f3ee15fb34cc43e5f940a20f3399728f41d7c28
LABEL org.opencontainers.image.title="orgflow-devops ldap (M0 thin wrapper)"
LABEL org.opencontainers.image.licenses="OpenLDAP-2.8"
LABEL org.opencontainers.image.licenses.note="OpenLDAP is OpenLDAP-2.8; upstream digest is locked in docs/运维/镜像与供应链.md"
# 薄封装：官方 osixia/openldap:1.5.0 + 固化初始用户 LDIF。
# LDIF 真源 config/ldap/50-users.ldif，由 scripts/sync-build-context.sh 同步到 build/。
# 放到 osixia 的 custom bootstrap 目录，配合 entrypoint --copy-service 在首启导入。
# 初始账号仅 M0 现有服务所需（svc-platform-admin / zeek.zhao）。
COPY build/50-users.ldif /container/service/slapd/assets/config/bootstrap/ldif/custom/50-users.ldif
COPY build/51-jenkins.ldif /container/service/slapd/assets/config/bootstrap/ldif/custom/51-jenkins.ldif
# 修复轮 T2：ldap 健康检查脚本 + license（真叠加内容）
COPY build/ldap-health.sh /usr/local/bin/ldap-health.sh
COPY build/LICENSE        /usr/share/doc/orgflow/LICENSE
