# [#95] REQ-M0-C2 文档站静态路由 + 每份服务指南补齐

- **Issue**：#95（https://github.com/zeek-zhao/orgflow-devops/issues/95）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`docs/95-service-docs`
- **依赖**：文档内容部分无依赖；路由部分依赖 #86
- **token 预算**：约 12 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 1（并发）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md` 与 `docs/会话交接.md` §0 / §3；需求编号与资料依据见 `docs/M0-增量需求总表.md`。

**本卡特别提示**：本卡只做 11 份服务文档四段补齐 + 静态站点生成脚本 + README 索引；config/routes.yaml 的 docs 路由留给批次 2（见 Issue #95 的拆分说明）。docs 域名 200 的验收在 #86 前无法执行，PR 必须列入未验证项，不得伪造通过。

---
> 需求索引：[M0 增量需求总表](https://github.com/zeek-zhao/orgflow-devops/blob/main/docs/M0-增量需求总表.md) §3 **REQ-M0-C2**；决策背景见 §0，网上资料核证见 §1，213 现状取证见 §2。
> **本 Issue 是需求真本**；执行副本在 `docs/task-cards/`，链路见 `docs/派单流程.md`。
> 里程碑 M0 · Project #5 · 批次 1 · 前置：#86

## 目标

`docs/` 经 Caddy 静态路由对外可访问；11 份服务文档统一补齐「使用指南 / 注意事项 / 设置 / 备份」四段；Homepage 从每条链接直达对应段落，用户点开就知道每份文档怎么用。

## 背景与取证

| 事实 | 值 | 来源 |
|---|---|---|
| 已有 11 份 `docs/services/*.md` + `备份与恢复.md` + `使用说明.md` | 不必再引新服务 | 213 实测 |
| 文档站是 A3 决策里「唯一受保护路由」 | 路由部分依赖 A3，文档内容补齐可先做 | 决策 B-网关收口 |
| `make test` 有服务文档覆盖自检 | 新增/改动要过自检 | `scripts/test_docs.py` |

## 范围

**改**
- `docs/services/*.md` 11 份统一六段（补齐四段）
- `docs/备份与恢复.md`、`README.md` 索引
- `config/routes.yaml`（新增 docs 路由，与 A3 对齐）、`services/router/` 渲染、`out/Caddyfile`

**新增**
- 静态站点生成脚本（把 `docs/*.md` 编成 HTML 或直接用文件服务）

## 验收

- [ ] `curl --noproxy "*" --ssl-no-revoke -I https://docs.org-devops.com/services/jenkins.html` → 200（路由部分需 A3 就绪）
- [ ] 11 份文档逐份 `grep -c "^## "` ≥ 6（含四个新增段）
- [ ] `make test` 的文档覆盖自检绿（贴输出）
- [ ] 反证：删掉某份文档的一段 → 覆盖自检必须红；恢复复绿

## 禁止事项

- 不得把含明文口令的内容放进文档站（虽受网关保护，仍按最小披露）
- 不得改 `docs/` 里已有的验收记录结论
- 不得手改 `out/Caddyfile`
- 不得自行合并 PR

## 依赖与前置

- [ ] 文档内容补齐无前置；静态路由部分依赖 #86
- [ ] `make test` 绿

## token 预算

约 12 万；超预算先停下汇报，不要硬推。

## 交付物

- [ ] 分支 `docs/95-service-docs`，提交信息符合 `docs/提交规范.md`
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

（派单方 2026-11-06 回填；执行方不用填）

- PR：PR #101（`merge/batch1`，Rebase 合并）
- 结果：main = `fa447db8`；本卡 commit `fa447db8c`。#95 与 #90/#92/#94 在 5 个文件冲突，按「双方内容都保留」解后复跑 `make test` RC=0、`scripts/test_service_doc_sections.py` RC=0（11 份文档四段齐全）。
- 与本卡的偏离：**本卡只完成文档内容部分**；`config/routes.yaml` 的 docs 静态路由仍留批次 2（依赖 #86），`curl -I https://docs.org-devops.com/services/jenkins.html → 200` 仍无法执行。
