# orgflow-devops

企业级 DevOps 平台单仓（**M0 最小核心**）。以 Jenkins 为唯一编排入口，自举「权限管理服务 + 路由注册服务 + Caddy 代理 + Nexus 制品 + 备份」底座；各服务的部署/备份由 **参数化 Jenkins Job** 驱动。

**M0 已关闭**（2026-11-01，三段验收全过）。现在什么状态、下一步做什么，看
[会话交接](docs/会话交接.md) 与 [待办](docs/待办.md)。

> 需求真本在 vault：`40-项目/orgflow-devops/orgflow-devops-需求方案.md`（v0.2.0）。
> 除需求外，本仓库的文档是**自洽**的 —— 接手不需要任何外部资料。

## M0 组件

| 组件 | 说明 |
|---|---|
| Jenkins | CI 主控 / 参数化 Job 入口（`https://jenkins.<domain>/`，受保护） |
| 权限管理服务 | OpenLDAP + LDAP Admin + Dex + OAuth2 Proxy（统一认证网关） |
| 路由注册服务 | `config/routes.yaml` → 渲染 Caddyfile → Caddy admin reload |
| Caddy | 唯一对外入口，按域名分站点（`:80` 跳转 / `:443` 站点，内部 CA 自签） |
| dnsmasq | 容器内 DNS：`*.<domain>` → Caddy 固定 IP |
| Homepage | 统一入口面板（`https://home.<domain>/`），一屏看到所有服务 |
| Nexus | 制品库 / 备份目标 |
| 备份 Job | 各服务数据卷/配置备份 |

域名路由的来由、固定 IP 表与排查手法见 [ADR-13](docs/ADR-13-域名路由.md)。

## 快速开始

```bash
cp .env.example .env        # 填域名/端口/账号；镜像 digest 由 tests/images.lock 锁定
make deploy                 # 起 M0 底座（域名与端口取自 .env）
make hosts                  # 生成 /etc/hosts 片段：域名 → 本机（局域网用 --write <IP>）
make ca                     # 安装 Caddy 内部 CA 根证书（自签 TLS 必需）
make jobs                   # 推送参数化 deploy/backup Job 到 Jenkins
```

**从 `https://home.org-devops.com/` 进**——一屏看到所有服务，点进去直达。
其它入口：`https://jenkins.org-devops.com/`（需登录）、`https://nexus.org-devops.com/`、
`https://ldapadmin.org-devops.com/`（需登录）、`https://auth.org-devops.com/ping`。
旧路径入口（`http://localhost:8080/jenkins`）已删除。

## 目录

```
config/         JCasC / routes.yaml / JJB job 定义
services/auth   权限管理服务编排（含 dex 配置模板）
services/dnsmasq 容器内 DNS（*.<domain> → Caddy）
services/router 路由注册服务（渲染 + reload）
shared-library  deployService / backupService 步骤
scripts/        deploy / hosts / ca / backup / lint
docs/           方案、ADR 与运维
tests/          镜像锁定 / bats 服务测试 / DinD harness
```

## 测试

`make test` 跑逻辑检查（含**文档相对链接**、**服务文档覆盖**与**IP 表一致性**），
`make test-bats` 在独立 DinD 栈内跑 `tests/bats/` 全部用例
（每服务冒烟 + stack/dns/tls/public + 备份恢复链路 + verify job 一致性 + 自举脚本幂等）。
bats 断言一律用
`curl --resolve <sub>.<domain>:<port>:127.0.0.1`，测的是 Caddy 的站点匹配而不是某个
`IP:端口`。运行要求、`KEEP=1` 调试和镜像升级步骤见
[M0 测试体系](docs/M0-测试体系.md)。

## 文档索引

| 想知道 | 去哪看 |
|---|---|
| **刚接手这个仓库，先读这一份** | [会话交接](docs/会话交接.md)（现状 + 下一步 + 陷阱速查） |
| **AI 会话开工 SOP（读什么、跑什么、不能碰什么）** | [AI 会话清单](docs/AI会话清单.md) |
| **平台日常怎么用（入口/登录/部署/备份/加路由）** | [使用说明](docs/使用说明.md) |
| **每个账号是什么、密码在哪、怎么登** | [账号与登录](docs/账号与登录.md) |
| **现在还有哪些事没做** | [待办](docs/待办.md)（Issue 索引，需求真本在 Issue 里） |
| **这一批优化需求的取证、编号与依赖链** | [M0 增量需求总表](docs/M0-增量需求总表.md) |
| **账号/组怎么命名、权限由谁决定** | [身份命名规范](docs/身份命名规范.md) |
| **M0 是怎么验的、验出了什么** | [M0 验收记录](docs/M0-验收记录.md)（三个真机缺陷复盘在 §12） |
| M0 设计：是什么、怎么跑、Job 怎么定义 | [M0 最小核心](docs/M0-最小核心.md) |
| 测试怎么跑、三层验证怎么分、怎么升 digest | [M0 测试体系](docs/M0-测试体系.md) |
| 某个服务怎么用、怎么部署、坏了怎么查 | [`docs/services/`](docs/services/)（11 份，统一六段） |
| 网络拓扑、固定 IP 表、分层排查决策树、局域网访问 | [网络架构](docs/network/arch.md) |
| 域名路由为什么这么做 | [ADR-13](docs/ADR-13-域名路由.md) |
| 镜像与 CI 流水线 | [M0 镜像与 CI](docs/M0-镜像与CI.md) |
| 备份怎么做、怎么演练恢复 | [备份与恢复](docs/备份与恢复.md) |
| 任务怎么派、验收怎么写 | [派单流程](docs/派单流程.md) |
| 提交身份与分支规则 | [提交规范](docs/提交规范.md) |
| Windows 侧验收脚本怎么用 | [win-acceptance](tools/win-acceptance/README.md) |

固定 IP 表会被脚本核对：`bash scripts/check-arch-ips.sh` 逐行比对真实容器地址，
改完 compose 记得跑一次。

## 约定

- 敏感信息只走 `.env`（不入库）与 Jenkins Credentials（Job 仅引用 ID）。
- 配置即代码：所有变更经 PR 合入（WF4），禁止控制台手工改生产。
