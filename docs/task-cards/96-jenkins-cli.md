# [#96] REQ-M0-B4 Jenkins CLI 四件套（list / get / run / log）

- **Issue**：#96（https://github.com/zeek-zhao/orgflow-devops/issues/96）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`feat/96-jenkins-cli`
- **依赖**：无
- **token 预算**：约 10 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 1（并发）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md` 与 `docs/会话交接.md` §0 / §3；需求编号与资料依据见 `docs/M0-增量需求总表.md`。

**本卡特别提示**：consoleText / api/json 属运行时确认，不得写成官方文档结论；凭据只从环境变量读。

---
> 需求索引：[M0 增量需求总表](https://github.com/zeek-zhao/orgflow-devops/blob/main/docs/M0-增量需求总表.md) §3 **REQ-M0-B4**；决策背景见 §0，网上资料核证见 §1，213 现状取证见 §2。
> **本 Issue 是需求真本**；执行副本在 `docs/task-cards/`，链路见 `docs/派单流程.md`。
> 里程碑 M0 · Project #5 · 批次 1 · 前置：无

## 目标

一个命令行脚本完成「列任务、取任务详情、带参数触发、下载构建日志」，每步打印请求与结果；凭据不落盘、不使用 crumb。

## 背景与取证

| 事实 | 值 | 来源 |
|---|---|---|
| `POST JENKINS_URL/job/JOB_NAME/buildWithParameters`，`curl --user USER:TOKEN --data id=123` | 官方逐字示例 | Jenkins Remote Access API |
| 官方原话 "API tokens are preferred instead of crumbs for CSRF protection." | 用 token 不用 crumb | 同上 |
| **该官方页没有逐字给出 `consoleText` / `api/json` endpoint** | `get` / `log` 必须在 213 运行时实测，不得写成官方文档结论 | 同上（否定结论） |

## 范围

**新增**
- `scripts/jenkins-cli.sh`（四个子命令 + 统一的错误处理与请求回显）
- `scripts/` 下自检用例

**改**
- `docs/services/jenkins.md` 用法段

## 验收

- [ ] `bash scripts/jenkins-cli.sh list` 列出 5 类 Job（贴输出）
- [ ] `... get deploy` 返回 JSON 且含 job 名
- [ ] `... run verify SERVICE=homepage` 返回 201/302 并打印 queue id
- [ ] `... log deploy last` 输出非空构建日志
- [ ] 四条命令都在 213 实测贴原样输出，并在文档里标注 `consoleText` / `api/json` 是运行时确认
- [ ] 反证：故意用错 API token → 四个子命令必须都非 0 退出且打印明确错误，不得静默成功

## 禁止事项

- 不得把密码/token 写进脚本、日志或文档（从 `.env` / 环境变量读）
- 不得用 crumb 作为首选（官方推荐 API token）
- 不得把 `consoleText` 写成「官方文档规定」
- 不得自行合并 PR

## 依赖与前置

- [ ] 无前置 Issue
- [ ] 213 上 `.env` 的 `JENKINS_ADMIN_ID` / `JENKINS_ADMIN_PASSWORD` 可读

## token 预算

约 10 万；超预算先停下汇报，不要硬推。

## 交付物

- [ ] 分支 `feat/96-jenkins-cli`，提交信息符合 `docs/提交规范.md`
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
