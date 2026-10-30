# orgflow-devops

企业级 DevOps 平台单仓（**M0 最小核心**）。以 Jenkins 为唯一编排入口，自举「权限管理服务 + 路由注册服务 + Caddy 代理 + Nexus 制品 + 备份」底座；各服务的部署/备份由 **参数化 Jenkins Job** 驱动。

> 需求与架构见 vault：`40-项目/orgflow-devops/orgflow-devops-需求方案.md`（v0.2.0）

## M0 组件

| 组件 | 说明 |
|---|---|
| Jenkins | CI 主控 / 参数化 Job 入口 |
| 权限管理服务 | OpenLDAP + LDAP Admin + OAuth2 Proxy（统一认证网关） |
| 路由注册服务 | `config/routes.yaml` → 渲染 Caddyfile → Caddy admin reload |
| Caddy | 唯一对外入口（`:8080`） |
| Nexus | 制品库 / 备份目标 |
| 备份 Job | 各服务数据卷/配置备份 |

## 快速开始

```bash
cp .env.example .env        # 填端口/账号/镜像
make render                 # routes.yaml -> out/Caddyfile
make deploy                 # 起 M0 底座
make jobs                   # 推送参数化 deploy/backup Job 到 Jenkins
```

## 目录

```
config/         JCasC / routes.yaml / JJB job 定义
services/auth   权限管理服务编排
services/router 路由注册服务（渲染 + reload）
shared-library  deployService / backupService 步骤
scripts/        deploy / backup / lint
docs/           方案与运维
```

## 约定

- 敏感信息只走 `.env`（不入库）与 Jenkins Credentials（Job 仅引用 ID）。
- 配置即代码：所有变更经 PR 合入（WF4），禁止控制台手工改生产。
