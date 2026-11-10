# OrgFlow DevOps(中文文档)

企业级 DevOps 平台单仓:以 **Jenkins 为唯一编排入口**,自举「权限管理
(OpenLDAP + Dex + OAuth2 Proxy)+ 路由注册 + Caddy 网关 + Nexus 制品库 +
备份恢复」底座;各服务的部署/备份由参数化 Jenkins Job 驱动,配置即代码。

> 🇬🇧 English overview: [README.md](README.md)

## 组件一览

| 组件 | 职责 |
|---|---|
| Jenkins | Pipeline CI/CD;LDAP 安全域 + 按组矩阵授权 |
| OpenLDAP + Dex + OAuth2 Proxy | 身份、OIDC、组授权网关(唯一受保护路由) |
| Caddy | TLS 网关、域名路由、内部 CA、静态文档站 |
| Nexus | 制品库(Docker/PyPI 仓库),LDAP 认证 |
| 路由注册服务 | `routes.yaml` → 渲染 Caddyfile → 热加载 + 注册 API |
| 备份/恢复 | 参数化 Job;sha256 校验的归档与恢复演练 |
| 合规门禁 | 公开发布的密钥/内网信息扫描 |

## 快速开始

```bash
cp .env.example .env          # 填域名/凭据
make deploy                   # 全栈自举(dnsmasq 先行,分批启动)
make jobs                     # 推送参数化 Job 到 Jenkins
```

日常使用:[docs/使用说明.md](docs/使用说明.md);各服务运维手册:[docs/services/](docs/services/)。

## 仓库结构

```
services/    各服务构建与配置(jenkins/router/auth 栈/dnsmasq)
config/      JCasC、routes.yaml、JJB Job 定义
scripts/     部署/备份/恢复/LDAP bootstrap/合规门禁
tests/       镜像钉版 + bats 集成测试(DinD)
docs/        架构、服务手册、使用指南
```

## License

[Apache-2.0](LICENSE)
