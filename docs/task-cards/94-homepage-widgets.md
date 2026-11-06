# [#94] REQ-M0-C1 Homepage 活性检测 + 时间/天气/界面 + 文档直链

- **Issue**：#94（https://github.com/zeek-zhao/orgflow-devops/issues/94）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`feat/94-homepage-widgets`
- **依赖**：无
- **token 预算**：约 10 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 1（并发）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md` 与 `docs/会话交接.md` §0 / §3；需求编号与资料依据见 `docs/M0-增量需求总表.md`。

**本卡特别提示**：siteMonitor / openmeteo 是二手资料，必须在 homepage 容器内实测版本支持；不得引入需 token 的 widget。

---
> 需求索引：[M0 增量需求总表](https://github.com/zeek-zhao/orgflow-devops/blob/main/docs/M0-增量需求总表.md) §3 **REQ-M0-C1**；决策背景见 §0，网上资料核证见 §1，213 现状取证见 §2。
> **本 Issue 是需求真本**；执行副本在 `docs/task-cards/`，链路见 `docs/派单流程.md`。
> 里程碑 M0 · Project #5 · 批次 1 · 前置：无

## 目标

首页能看到每个服务的存活状态、时间、天气；每份文档有可直接点开的链接并写清「怎么用」；不注入任何需要凭据的 widget。

## 背景与取证

| 事实 | 值 | 来源 |
|---|---|---|
| `widgets.yaml` 已有 resources / datetime / search，并写死「首页公开，不注入需要 token 的 widget」 | 天气与活性检测必须走免凭据方案 | 213 实测 |
| `siteMonitor` 是轻量 HTTP HEAD 监测（约 5 分钟一轮），服务卡有 `ping` 字段 | 不需凭据 | gethomepage 配置实践（**二手，需容器内实测**） |
| Homepage 有 `openmeteo` provider 与 `customapi` widget | **二手，需容器内实测版本是否支持** | gethomepage 源码/配置实践 |
| Open-Meteo 非商业 + <10,000 次/日 下 `api.open-meteo.com` 不需要 `apikey`，当前天气走 `/v1/forecast?current=...` | 官方逐字 | open-meteo.com/en/docs |
| bookmark 的值必须是列表，否则前端 `new URL(e.href)` 会炸 | 既有踩坑 | `config/homepage/bookmarks.yaml` 注释 |

## 范围

**改**
- `config/homepage/widgets.yaml`（siteMonitor / 天气 / datetime）
- `config/homepage/services.yaml`（每卡加文档 href + `ping`）
- `config/homepage/bookmarks.yaml`（本地文档区）
- `config/homepage/settings.yaml`（界面）
- `docs/services/homepage.md`

## 验收

- [ ] 在 homepage 容器内确认所用 widget 类型在当前镜像版本存在（贴检查命令与输出；二手资料必须实测）
- [ ] 首页 HTTP 200 且 6 个服务卡都显示状态
- [ ] 天气请求 URL 不含 `apikey`（贴配置片段）
- [ ] `grep -c "docs/" config/homepage/services.yaml` ≥ 服务数
- [ ] `make test` 退出码 0
- [ ] 反证：停掉 `of-nexus` → 首页对应状态变 down；恢复后变 up（贴两次）

## 禁止事项

- 不得注入任何需要 token/凭据的 widget（首页是公开站点）
- 不得使用需要 API key 的天气服务
- 不得破坏 bookmark 值必须是列表的约束
- 不得把明文口令摆到首页
- 不得自行合并 PR

## 依赖与前置

- [ ] 无前置 Issue
- [ ] 需确认 homepage 容器镜像版本

## token 预算

约 10 万；超预算先停下汇报，不要硬推。

## 交付物

- [ ] 分支 `feat/94-homepage-widgets`，提交信息符合 `docs/提交规范.md`
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
- 结果：main = `fa447db8`；本卡 commit `10b310a1f`。集成分支 `make test` RC=0，含 `scripts/test_homepage_config.py` 12 个用例全绿、`identity-check` RC=0。
- 与本卡的偏离：首页 HTTP 200 / 6 张卡实际渲染 / 状态点翻转 / 天气实取未做运行时验证；容器内 v2.7.0 widget 版本核对与配置层反证已在交付评论中给出。213 主工作区 `config/homepage/` 属主 `rdsw`、jenkins 无写权限，新配置尚未部署到运行中的 homepage。
