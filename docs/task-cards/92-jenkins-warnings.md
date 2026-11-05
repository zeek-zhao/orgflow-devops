# [#92] REQ-M0-B3 Jenkins 警告清零／不能解决的逐条给理由

- **Issue**：#92（https://github.com/zeek-zhao/orgflow-devops/issues/92）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`docs/92-jenkins-warnings`
- **依赖**：无
- **token 预算**：约 8 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 1（并发）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md` 与 `docs/会话交接.md` §0 / §3；需求编号与资料依据见 `docs/M0-增量需求总表.md`。

**本卡特别提示**：警告列表必须从 213 运行时抓取并贴原样输出，不得凭印象编写。

---
> 需求索引：[M0 增量需求总表](https://github.com/zeek-zhao/orgflow-devops/blob/main/docs/M0-增量需求总表.md) §3 **REQ-M0-B3**；决策背景见 §0，网上资料核证见 §1，213 现状取证见 §2。
> **本 Issue 是需求真本**；执行副本在 `docs/task-cards/`，链路见 `docs/派单流程.md`。
> 里程碑 M0 · Project #5 · 批次 1 · 前置：无

## 目标

Manage Jenkins 的警告逐条处置：能修的修掉，不能修的写进「警告台账」并说明原因与复核日期；台账条目数与实际警告数一致。

## 背景与取证

| 事实 | 值 | 来源 |
|---|---|---|
| 用户要求「解决 Jenkins 警告，不能解决的给出理由」 | 需逐条台账 | 2026-11-05 需求 |
| 警告列表需从运行时抓取，不能凭印象写 | `/manage/` 与 `/administrativeMonitor/` | Jenkins |

## 范围

**改**
- `docs/services/jenkins.md` 新增「警告台账」段（编号 / 现象 / 处置 / 理由 / 复核日期）
- 相关 compose / JCasC / 反向代理配置（仅针对可修项）

**新增**
- `scripts/` 下抓警告列表的只读脚本

## 验收

- [ ] 在 213 抓 `/manage/` 与 `/administrativeMonitor/` 的警告列表（贴命令与原样输出）
- [ ] 台账条目数 = 实际警告数，每条有「已修」或「不修 + 理由」
- [ ] `make test` 退出码 0
- [ ] 反证：人为制造一条已知警告（如反向代理 URL 不匹配）→ 台账核对脚本必须报「未登记」；登记后复绿

## 禁止事项

- 不得用隐藏/抑制警告的方式「清零」
- 不得靠升/降 Jenkins 版本绕过
- 不得把猜测写成事实
- 不得自行合并 PR

## 依赖与前置

- [ ] 无前置 Issue
- [ ] 需要人工动作：在 Jenkins 管理页复核警告文案

## token 预算

约 8 万；超预算先停下汇报，不要硬推。

## 交付物

- [ ] 分支 `docs/92-jenkins-warnings`，提交信息符合 `docs/提交规范.md`
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
