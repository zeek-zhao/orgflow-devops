# orgflow-devops

企业级 DevOps 平台单仓。以 Jenkins 为唯一编排入口，自举「权限管理服务 + 路由注册服务 +
Caddy 代理 + Nexus 制品 + 备份」底座；各服务的部署/备份由**参数化 Jenkins Job** 驱动，
全部配置即代码，不靠控制台点选。

> English: [README.md](README.md)

## 组件

| 组件 | 说明 |
|---|---|
| Jenkins | CI 主控 / 参数化 Job 入口（`https://jenkins.<domain>/`，受保护） |
| 权限管理服务 | OpenLDAP + LDAP Admin + Dex + OAuth2 Proxy（统一认证网关） |
| 路由注册服务 | `config/routes.yaml` → 渲染 Caddyfile → Caddy admin reload |
| Caddy | 唯一对外入口，按域名分站点（`:80` 跳转 / `:443` 站点，内部 CA 自签） |
| dnsmasq | 容器内 DNS：`*.<domain>` → Caddy 固定 IP |
| Homepage | 统一入口面板（`https://home.<domain>/`），一屏看到所有服务 |
| Nexus | 制品库 / 备份目标 |
| 备份 Job | 各服务数据卷/配置备份，sha256 校验 + 恢复演练 |

域名路由的来由、固定 IP 表与排查手法见 [ADR-13](docs/ADR-13-域名路由.md)。

## 快速开始

```bash
make hooks                  # 安装 git 钩子（提交身份校验 + 主干保护），新克隆必做
cp .env.example .env        # 填域名/端口/账号；镜像 digest 由 tests/images.lock 锁定
make deploy                 # 起底座（镜像从 GHCR 拉，域名与端口取自 .env）
make hosts                  # 生成 /etc/hosts 片段：域名 → 本机（局域网用 --write <IP>）
make ca                     # 安装 Caddy 内部 CA 根证书（自签 TLS 必需）
make jobs                   # 推送参数化 deploy/backup Job 到 Jenkins
```

**镜像只有一个来源：GitHub Actions 构建并推到 GHCR，本地只拉不建。**
所有包都是 public，拉取不需要 `docker login`，也不需要任何凭据。
`make deploy` 前会过一道闸门（`scripts/check-image-source.sh`）：若镜像上下文
（Dockerfile / JCasC / 路由渲染器等）自上次构建以来改过，就直接拒绝部署 ——
否则会拉到上一版镜像、健康检查全绿、跑的却是旧代码。

改了镜像相关内容要本地立刻验证时：

```bash
make build-local            # 显式本地构建，产物不推 GHCR，只供本地验证
USE_GHCR=0 make deploy      # 用本地这套镜像起来
```

这两条不是等价选项：本地构建是为了在提交前验证 Dockerfile 改动，
共享环境一律从 GHCR 部署。

**从 `https://home.<domain>/` 进**——一屏看到所有服务，点进去直达。
其它入口：`https://jenkins.<domain>/`（需登录）、`https://nexus.<domain>/`、
`https://ldapadmin.<domain>/`（需登录）、`https://auth.<domain>/ping`。

## 目录

```
config/          JCasC / routes.yaml / JJB job 定义
services/auth    权限管理服务编排（含 dex 配置模板）
services/dnsmasq 容器内 DNS（*.<domain> → Caddy）
services/router  路由注册服务（渲染 + reload）
shared-library   deployService / backupService 步骤
scripts/         deploy / doctor / hosts / ca / backup / 门禁 / 生成器
tools/           Jenkins CLI / Windows 验收脚本 / JJB
tests/           镜像锁定 / bats 服务测试 / DinD harness
docs/            架构、ADR、逐服务手册、使用说明
```

## 测试

```bash
make test         # 静态与行为检查（路由/Job/文档登记册/各类门禁）
make test-bats    # DinD 内起 10 个服务 + 部署 nexus，跑 tests/bats/ 全部用例
make docs-check   # 文档登记册门禁（IEEE 828 轻量落地）
make doctor       # 只读环境自检
```

`make test-bats` 一律本地构建：它验的是**本次提交的源码**能不能起来，
所以从不使用 GHCR 上已构建好的镜像（那测的是更早的提交）。

bats 断言一律用 `curl --resolve <sub>.<domain>:<port>:127.0.0.1`，
测的是 Caddy 的站点匹配而不是某个 `IP:端口`。运行要求、`KEEP=1` 调试与镜像升级步骤见
[M0 测试体系](docs/M0-测试体系.md)。

## 文档

从 [文档地图](docs/文档地图.md) 开始（按角色给阅读顺序）；常用入口：

| 想知道 | 去哪看 |
|---|---|
| 这东西是什么、怎么跑、Job 怎么定义 | [M0 最小核心](docs/M0-最小核心.md) |
| 平台日常怎么用（入口/登录/部署/备份/加路由） | [使用说明](docs/使用说明.md) |
| 测试怎么跑、三层验证怎么分、怎么升 digest | [M0 测试体系](docs/M0-测试体系.md) |
| 镜像与 CI 流水线 | [M0 镜像与 CI](docs/M0-镜像与CI.md) |
| 某个服务怎么用、怎么部署、坏了怎么查 | [`docs/services/`](docs/services/)（11 份统一六段） |
| 网络拓扑、固定 IP 表、分层排查决策树 | [网络架构](docs/network/arch.md) |
| 域名路由为什么这么做 | [ADR-13](docs/ADR-13-域名路由.md) |
| 备份怎么做、怎么演练恢复 | [备份与恢复](docs/备份与恢复.md) |
| 我们在分发什么、欠谁什么 | [开源合规](docs/开源合规.md) + [第三方声明](THIRD_PARTY_NOTICES.md) |
| 某个 issue 改哪份文档、哪段代码 | [问题索引](docs/问题索引.md) |
| 每篇文档什么状态、谁负责、何时该重看 | [文档登记册](docs/文档登记册.md) |
| Windows 侧验收脚本怎么用 | [win-acceptance](tools/win-acceptance/README.md) |

固定 IP 表会被脚本核对：`bash scripts/check-arch-ips.sh` 逐行比对真实容器地址，
改完 compose 记得跑一次。

## 文档站（静态 HTML，离线生成）

`python3 scripts/gen_docs_site.py` 把 `docs/**/*.md` 编成同构 `.html`：
`docs/services/jenkins.md` → `out/docs-site/services/jenkins.html`，并生成 `index.html`。
纯标准库、不联网、可重复跑；Markdown 里的 `.md` 链接会改写成 `.html`，
`##` 标题生成锚点，索引页按目录分组。

编入内容会再过一次口令兜底脱敏，指向仓库外部的链接降级为纯文本，避免死链。

## 约定

- 敏感信息只走 `.env`（不入库）与 CI 凭据（Job 仅引用 ID）。
- 配置即代码：所有变更经 PR 合入，禁止在生产上手工改。
- 提交身份、分支与 PR 规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可

[Apache-2.0](LICENSE)。第三方组件及许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，
许可证原文在 [licenses/](licenses/)。
