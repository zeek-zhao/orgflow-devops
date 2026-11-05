# [#90] REQ-M0-B1 自定义 Jenkins image + 默认插件清单

- **Issue**：#90（https://github.com/zeek-zhao/orgflow-devops/issues/90）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`feat/90-jenkins-plugins`
- **依赖**：无
- **token 预算**：约 12 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 1（并发）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md` 与 `docs/会话交接.md` §0 / §3；需求编号与资料依据见 `docs/M0-增量需求总表.md`。

**本卡特别提示**：新增 image 与插件清单；不要动已发布的 GHCR tag，新 tag 必须锁 digest。

---
> 需求索引：[M0 增量需求总表](https://github.com/zeek-zhao/orgflow-devops/blob/main/docs/M0-增量需求总表.md) §3 **REQ-M0-B1**；决策背景见 §0，网上资料核证见 §1，213 现状取证见 §2。
> **本 Issue 是需求真本**；执行副本在 `docs/task-cards/`，链路见 `docs/派单流程.md`。
> 里程碑 M0 · Project #5 · 批次 1 · 前置：无

## 目标

Jenkins 镜像自带 pipeline 等常用插件，装机即可用，不靠人工 UI 点装；digest 锁定且 GHCR 可复现。

## 背景与取证

| 事实 | 值 | 来源 |
|---|---|---|
| 仓库无 `Dockerfile` / `plugins.txt`，Jenkins 用官方镜像 + JCasC | 插件靠人工/默认 | 213 实测 |
| `docker-compose.ghcr.yml` 用 digest 锁定镜像 | 新增 image 也要锁 | 仓库 |
| 213/214 无法访问 Docker Hub，镜像只能走 GHCR | `USE_GHCR=1` | 环境事实 |

## 范围

**新增**
- `services/jenkins/Dockerfile`
- `services/jenkins/plugins.txt`

**改**
- `docker-compose.yml`（build 段）、`docker-compose.ghcr.yml`、`tests/images.lock`、`Makefile`
- `docs/M0-镜像与CI.md`、`docs/services/jenkins.md`

## 验收

- [ ] `docker compose config` 能渲染（贴退出码）
- [ ] 容器内插件清单包含 `workflow-aggregator`、`git`、`credentials`、`ldap`、`configuration-as-code`（贴 `ls` 或 CLI 输出）
- [ ] `grep -c "workflow-aggregator" services/jenkins/plugins.txt` → `1`
- [ ] 反证：从 plugins.txt 删掉 `workflow-aggregator` → 镜像自检用例必须红；恢复复绿

## 禁止事项

- 不得改动已发布的 GHCR tag 内容（新增 tag）
- 不得在未锁 digest 时推送
- 不得跳过 `tests/images.lock` 同步
- 不得自行合并 PR

## 依赖与前置

- [ ] 无前置 Issue
- [ ] `make test` 绿

## token 预算

约 12 万；超预算先停下汇报，不要硬推。

## 交付物

- [ ] 分支 `feat/90-jenkins-plugins`，提交信息符合 `docs/提交规范.md`
- [ ] PR 正文含：做了什么 / 关键决策与偏离 / 验收实测表 / 未验证项
- [ ] 验收输出原样贴进交付说明（命令 + 真实输出，不要转述）
## 本卡的派工边界（派单方补充，不改动 Issue 需求）

- 在**独立 git worktree** 里工作（`git worktree add /tmp/wt-<issue> -b <分支> origin/main`），
  不改 213 主工作区、不碰运行中的容器、不改 `.env`。
- 禁止执行 `make down -v`、`USE_GHCR=1 make deploy` 以及任何会重启/重建线上栈的命令。
- 提交前跑 `make test`；提交信息符合 `docs/提交规范.md`，author 恒为
  `zeek.zhao <zeek.zhao@foxmail.com>`，不带 AI 署名。
- 本轮**只提交并推送分支，不要开 PR、不要自行合并**（派单方统一 rebase 合并）。
- 交付时报告：分支名、commit hash、`make test` 原样输出、验收条目逐条实测结果、未验证项。

## 交付后的记录

（派单方填，执行方不用填）

- PR：#
- 结果：
- 与本卡的偏离：
