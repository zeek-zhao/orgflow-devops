# services/ — 服务手册

每个自托管服务一册：职责、配置点、验证命令、已知边界。故障排查先来这里。

| DOC-ID | 文档 | 服务 |
|---|---|---|
| DOC-R-010 | [caddy](caddy.md) | 网关 / TLS 终止 |
| DOC-R-020 | [router](router.md) | 路由真源渲染器 + Caddy 控制 |
| DOC-R-011 | [dex](dex.md) | OIDC 身份提供 |
| DOC-R-019 | [oauth2-proxy](oauth2-proxy.md) | 网关认证转发 |
| DOC-R-016 | [ldap](ldap.md) | 目录服务（用户/组/部门） |
| DOC-R-014 | [jenkins](jenkins.md) | CI 引擎 |
| DOC-R-015 | [jenkins-agent](jenkins-agent.md) | 构建执行节点 |
| DOC-R-018 | [nexus](nexus.md) | 制品仓库（Docker/PyPI/Maven/NuGet） |
| DOC-R-017 | [ldapadmin](ldapadmin.md) | 目录管理界面 |
| DOC-R-013 | [homepage](homepage.md) | 门户仪表盘 |
| DOC-R-012 | [dnsmasq](dnsmasq.md) | 内网 DNS |
