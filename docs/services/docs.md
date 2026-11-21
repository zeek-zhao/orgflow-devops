# docs —— 在线文档站（MkDocs Material）

把仓库 `docs/` 里的 Markdown 构建成静态站点，经网关 `docs.<域名>` 提供。
旧实现让 Caddy 的 `file_server` 直接吐 Markdown 源码，浏览器打开看到的是纯文本；
现在是真站点（左侧导航、搜索、Mermaid 图）。

- 容器：`of-docs`（`config/services.yml` 里 start_order=90，固定 IP 末段 28）
- 宿主机端口：无发布端口，只经 Caddy 反代
- 访问：`https://docs.<gateway.domain>`（唯一受网关认证保护的路由，`#86`）
- 构建产物：卷 `docs_site`（Caddy 只读挂载 `/srv/docs`）

## 使用指南

## 改完文档怎么生效

1. 改完 `docs/**/*.md` 后执行 `docker compose restart docs`，容器启动时会重新构建。
2. 浏览器打开 `https://docs.<域名>`；未登录会先跳 `auth.<域名>` 走 OIDC。
3. 只想本地看效果：`docker compose logs docs` 里出现 `== docs 站点已生成 ==` 即可访问。

## 注意事项

## 权限与构建

- 只有 `docs-users` 组的 LDAP 成员能进（`config/routes.yaml` 里 docs 站点带 `forward_auth`）。
- 构建失败时容器不会健康：healthcheck 查的是 `/site/index.html` 是否存在，
  不是进程是否存活——「构建失败但容器还在跑」是这个服务最容易踩的坑。
- `mkdocs.yml` 漏登记一篇文档不会报错（站点里就是没有它）；漏引用一张图片会让
  `--strict` 直接失败，看 `docker compose logs docs` 的最后一行。

## 设置

| 项 | 位置 | 说明 |
|---|---|---|
| 镜像 | `services/docs/Dockerfile` | `squidfunk/mkdocs-material:9.8.2`（digest 钉在 `tests/images.lock`） |
| 站点配置 | `mkdocs.yml` | 导航结构、主题、插件 |
| 内容根 | `docs/` | 全部 Markdown；新增文档要在 `docs/文档登记册.md` 登记 |
| 构建命令 | `services/docs/compose.yml` | `mkdocs build --clean --strict --site-dir /site` |
| 路由 | `config/routes.yaml` | docs 站点带认证；改完 `make render` |

## 备份

站点是从仓库内容构建出来的派生物，**不需要备份**：

1. 内容真源在 git（`docs/`），恢复仓库即恢复内容。
2. 卷 `docs_site` 随时可重建：`docker compose restart docs`。
3. 真要清空重来：`docker compose down docs && docker volume rm <项目>_docs_site`，
   再 `docker compose up -d docs`。

## 需求与测试

- 需求：`REQ-M0-C2`（在线文档页可访问且只对授权用户开放），见 [M0-C-呈现与文档](../requirements/M0-C-呈现与文档.md)。
- 用例：`tests/bats/34_router_api.bats`（路由渲染与认证标记）、`tests/bats/21_homepage.bats`（入口卡片指向 docs）。
- 服务×需求×测试总表：[服务×需求×测试矩阵](../engineering/服务×需求×测试矩阵.md)。
- 真机抽检：`curl -sk -o /dev/null -w '%{http_code}' https://docs.<域名>/` 期望 `302`（未登录跳认证）；
  带会话访问期望 `200` 且响应里有站点标题。
