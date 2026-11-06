# [#91] REQ-M0-B2 Job 流水线化，每一步可见

- **Issue**：#91（https://github.com/zeek-zhao/orgflow-devops/issues/91）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`feat/91-job-pipeline`
- **依赖**：#90（**已合并**，`ff5a7b357`，PR #101；自定义 Jenkins image + 默认插件清单已入库）
- **token 预算**：约 15 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 2（可与 #85 并行：本卡只碰 Job 定义 / 共享库，不碰 LDAP）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md`、`docs/会话交接.md` §0/§3
> 与 `docs/派单流程.md`；需求编号与资料依据见 `docs/M0-增量需求总表.md` §3 REQ-M0-B2。

**本卡特别提示**：`make check-pins` 目前 RC=2（Jenkins 自定义镜像 digest 仍是占位），
那是 #90 的**上线闸门遗留**，与本卡无关；不要为了让它变绿而编造 sha256，也不要改 `tests/images.lock`。

## 目标

deploy / backup / restore / verify / nexus 五类 Job 改成 Pipeline，每个阶段有独立 stage 与日志分段，
取代一长串不可分辨的 shell；构建页能直接看到每步耗时与结果。

## 背景与取证

| 事实 | 值 | 来源 |
|---|---|---|
| 5 类 Job 由 Jenkins Job Builder 定义在 `config/job_definitions/`，`make jobs` 推送 | 改造入口 | 仓库 |
| `shared-library/` 已有 `deployService` / `backupService` 步骤 | 可复用 | 仓库 |
| Jenkins 镜像插件清单已含 `workflow-aggregator` / `git` / `credentials` / `ldap` / `configuration-as-code` | pipeline 运行时依赖已声明 | #90 / `services/jenkins/plugins.txt` |
| `make jobs` 推送需要 Jenkins 运行时；**本轮禁止连线上 Jenkins** | 验收降级为离线渲染 + 静态 stage 检查 | 派工边界 |

## 范围

**改**
- `config/job_definitions/` 五类定义改成 pipeline（每类 ≥2 个 stage，stage 名不得重复）
- `shared-library/` 步骤拆分，保留既有参数与凭据注入方式（secret file，不写明文）
- `Makefile` 的 `jobs` 目标说明与 `docs/M0-最小核心.md`
- `tests/bats/` 的 verify job 一致性用例

**新增**
- `scripts/` 下 Job 定义静态自检（stage 数量、重名、每 stage 非空）

## 验收

- [ ] `grep -rc "stage(" config/job_definitions/` 每类 ≥ 2（贴逐类计数）
- [ ] `make jobs-test` 或等价离线渲染退出码 0（贴输出）；**`make jobs` 真实推送/构建页 stage 列表降级为未验证项**，不得伪造截图或 API 返回
- [ ] `tests/bats/` verify job 一致性用例仍绿（若为 DinD 用例且本轮不可跑，明确标未验证）
- [ ] `make test` 退出码 0（贴原样输出）
- [ ] 反证：把某两个 stage 名字改成重复 → 静态检查必须报重名；改回后复绿（贴两次输出）
- [ ] 反证：把某 stage 体清空（只剩空 stage）→ 静态检查必须红；恢复复绿

## 禁止事项

- 不得为了「看起来有 stage」把单条 shell 拆成空 stage
- 不得改 `tests/images.lock`（#90 的 digest 占位由派单方另行处理）
- 不得把 `.env` 真值 / `GITHUB_TOKEN` 写进 Job 定义、文档或日志
- 不得连线上 Jenkins 执行 `make jobs`、不得重启/停止任何容器
- 不得为了过测试放宽断言
- 不得自行合并 PR

## 依赖与前置

- [ ] 前置 Issue #90 已合并（`git log --oneline origin/main | grep ff5a7b357` 有输出）
- [ ] `services/jenkins/plugins.txt` 存在且含 `workflow-aggregator`
## 本卡的派工边界（派单方补充，不改动 Issue 需求）

- 在**独立 git worktree** 里工作，不改 213 主工作区、不碰运行中的容器、不改 `.env`。
- 禁止执行 `make down -v`、`USE_GHCR=1 make deploy` 以及任何会重启/重建线上栈的命令。
- 提交前跑 `make test`；提交信息符合 `docs/提交规范.md`，author 恒为
  `zeek.zhao <zeek.zhao@foxmail.com>`，不带 AI 署名。
- 本轮**只提交并推送分支，不要开 PR、不要自行合并**（派单方统一 rebase 合并）。
- 交付时报告：分支名、commit hash、`make test` 原样输出、验收条目逐条实测结果、未验证项。
- 基线：以开工时 `origin/main` 为准（本卡落库时 = `2f5bf23`）。开工前必须 `git fetch origin --prune` 复核并记录实际 sha；若已前进，停下汇报，不要自行 rebase。

## 交付后的记录

（派单方填，执行方不用填）

- PR：#
- 结果：
- 与本卡的偏离：
