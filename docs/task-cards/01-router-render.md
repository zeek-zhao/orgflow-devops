# [01] 路由注册服务：routes.yaml → Caddyfile 渲染 + 热加载

- **Issue**：#1
- **PR**：#6
- **分支**：`feat/1-router-render`
- **类型**：回溯重建（原文是一段话的派单 prompt，验收口径按当前仓库状态重写）
- **依赖**：无
- **token 预算**：约 8 万 token

## 目标

新增 `router` 服务，把 `config/routes.yaml` 声明的路由渲染成 Caddyfile，由它驱动 Caddy。
改路由只改 YAML，**不改 Caddyfile、不重启 Caddy**：渲染产物变化后 Caddy 通过 `POST /load` 热加载，
旧路由在加载成功前不中断。

渲染失败（YAML 语法错、字段缺失、`upstream` 指向不存在的服务）必须**不落盘**、非 0 退出，
并保持上一版 Caddyfile 继续生效——**不能把 Caddy 弄挂**。

## 背景与取证

| 事实 | 值 / 结论 | 怎么来的 |
|---|---|---|
| Caddy 有 admin API | `POST localhost:2019/load`，body 为完整 Caddyfile，成功返回 `200` | `curl -X POST --data-binary @Caddyfile localhost:2019/load` |
| Caddy 的 admin 端口默认只在容器内 | 需显式 `admin localhost:2019` 才能被同容器内进程访问 | 容器内 `ss -ltn` |
| router 自身需要一个健康端点 | 渲染成功与否无法从外部观察，需要 `/healthz` | 见 PR #9 的就绪闸门需求 |
| 无 catch-all 时未匹配路径返回空 200 | Caddy 无兜底站点，`GET /nope` → `200` 空 body，排查时会被误认为「服务正常」 | `curl -o /dev/null -w '%{http_code}' localhost:8080/nope` |

## 范围

**改**

| 文件 | 改法 |
|---|---|
| `services/router/render.py` | `parse_routes()` 读 YAML → 校验 → 生成 Caddyfile 文本；`render()` 写临时文件再原子替换；失败时保留旧文件并非 0 退出 |
| `services/router/reload.sh` | 轮询渲染产物 mtime，变化则 `POST /load`；加载失败打印 Caddy 响应体，不退出进程 |
| `services/router/Dockerfile` | 基于 `python:3.12-slim`，装 `caddy` 与 `curl` |
| `services/router/README.md` | 渲染规则、字段含义、排查命令 |
| `docker-compose.yml` | 新增 `router` 服务；`caddy` 的 Caddyfile 改为挂载 router 的产物目录 |

**新增**

| 文件 | 内容 |
|---|---|
| `services/router/test_render.py` | 纯逻辑测试，不依赖 docker：路由解析、字段校验、渲染结构、失败不落盘 |

**删**

| 文件 | 理由 |
|---|---|
| 手写的 `Caddyfile` | 两份真源会漂移，路由只能由 YAML 生成 |

## 验收

- [ ] `python3 services/router/test_render.py` → 退出码 `0`，末行 `OK`
- [ ] `python3 services/router/render.py --routes config/routes.yaml --out /tmp/cf` → 打印 `(5 routes)`
- [ ] `grep -c '^https://' /tmp/cf` → `5`
- [ ] `grep -c 'forward_auth' /tmp/cf` → `1`（只有 `auth: true` 的 jenkins 站点有）
- [ ] `grep -o 'redir \* https://[^/]*' /tmp/cf` → `redir * https://auth.org-devops.com`
- [ ] `make render` → 退出码 `0`，末行 `rendered out/Caddyfile + out/dex/config.yaml`
- [ ] `bash -n services/router/reload.sh` → 退出码 `0`
- [ ] `docker compose config -q` → 退出码 `0`
- [ ] 反证：把某条路由的 `subdomain` 改成和另一条相同 → `make render` **非 0 退出**，报「subdomain 重复」；
      且 `out/Caddyfile` 的 mtime **未变**（`stat -c %Y` 前后相同）。`git checkout` 后复跑绿
- [ ] 反证：把 `routes.yaml` 缩进改坏 → `make render` 非 0 退出；`git checkout config/routes.yaml` 后复跑绿

> 别拿「upstream 指向不存在的服务」当反证：`render.py` 只校验字段格式与唯一性，
> **不探测 upstream 是否连通**（连通性归 bats 管）。选错反证会得到一个「非 0 但原因不对」的假通过。

## 禁止事项

- 不得在 `render.py` 里硬编码任何路由：路由只有 `config/routes.yaml` 一个来源
- 不得让渲染失败时仍然写出 Caddyfile：半截产物会让 Caddy 加载后丢路由
- 不得为「让测试过」而放宽 `test_render.py` 的断言
- 不得自行合并 PR

## 依赖与前置

- [ ] `docker compose version` → `v2.x`
- [ ] `python3 -c "import yaml"` → 返回 `0`（渲染依赖 PyYAML）

## 交付物

- [ ] 分支 `feat/1-router-render`，提交信息符合 `docs/提交规范.md`
- [ ] PR 正文含：做了什么 / 关键决策 / 验收实测表 / 未验证项
- [ ] 验收输出原样贴进 PR（命令 + 真实输出）

## 当年实测（PR #6 记录）

| 项 | 结果 |
|---|---|
| `services/router/test_render.py` | 10/10 |
| `make render` | 生成 Caddyfile，路由数与 YAML 一致 |
| `POST /load` | 200 |
| 改 routes 后新路径可达 | 是，旧路径不中断 |

## 与本卡的偏离

- 当年 `/healthz` 是 PR #9 补的（就绪闸门需要），本卡已把它并入范围
- 当年 Caddyfile 里没有 catch-all，`GET /nope` 返回空 `200`；兜底 404 是 #11 补的
- 当年是路径前缀路由（`/jenkins`），现在是域名路由（`jenkins.<domain>`），见 ADR-13。
  本卡的验收命令已按当前状态改写，`handle_path` 计数改为站点计数
