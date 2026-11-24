FROM osixia/phpldapadmin:0.9.0@sha256:d112b82be1336f91e028b0348755133fda333992355b533419355a65c32ff9ad
LABEL org.opencontainers.image.title="orgflow-devops ldapadmin (M0 thin wrapper)"
LABEL org.opencontainers.image.licenses="GPL-2.0-only"
LABEL org.opencontainers.image.licenses.note="phpLDAPadmin is GPL-2.0; upstream digest is locked in docs/engineering/镜像与供应链.md"
# 薄封装：官方 osixia/phpldapadmin:0.9.0。
# 登录参数（LDAP host / HTTPS 开关）不写死在镜像里，由 compose environment 注入，
# 改后端 LDAP 地址无需重建镜像。这里仅固化默认值说明，作为可独立重建的最小薄封装层。
ENV PHPLDAPADMIN_LDAP_HOSTS=ldap \
    PHPLDAPADMIN_HTTPS=false
