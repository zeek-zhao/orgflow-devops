# orgflow-minimal-devops

一套从零构建的最小 DevOps 底座：7 个容器、单一入口、内部 CA、统一身份、配置即代码。

- dnsmasq → certs-init → caddy → ldap → ldapadmin → homepage → router
- 全 Docker Compose，镜像按 sha256 digest 锁定，基底统一 Ubuntu 24.04
- 集成分支 `feat/m0-minimal`；一个功能 = 一个 Issue = 一个 PR = 合并即关单

> 本分支从零实现，`main` 仅作写法参考。
