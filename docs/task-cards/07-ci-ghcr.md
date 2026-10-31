# [07] CI：Actions 构建全部镜像并推 GHCR + 跑 bats

- **Issue**：#12
- **PR**：#14
- **分支**：`feat/12-ci-ghcr`
- **类型**：回溯重建（原文是一段话的派单 prompt，验收口径按当前仓库状态重写）
- **依赖**：#11（bats 体系）
- **token 预算**：约 15 万 token

## 目标

用 GitHub Actions 把所有镜像**经流水线生成并推到 GHCR**，并在 CI 里跑 bats。

1. **自建镜像由流水线构建**：`router` / `jjb` / `m0-test` → `ghcr.io/zeek-zhao/orgflow-devops/<name>`，
   推送后把 digest 记进 job summary + artifact，供人工回写锁定表
2. **上游镜像由流水线搬运**：`skopeo copy --all --preserve-digests` 把上游镜像镜像到 `mirror-*`，
   **digest 必须逐字节不变**（跨仓库改名不换 digest）
3. **CI 跑测试**：PR 与 push 都跑 `make test-bats`，红了就挡住合并
4. 提供 `docker-compose.ghcr.yml`：一键把栈切到 GHCR 镜像，让拉不到 Docker Hub 的环境也能起栈

## 背景与取证

#11 把测试体系建起来了，但还有三个空洞：

1. **镜像仍是本地构建**：谁构建的、用什么基座、产物 digest 是多少，全无记录。换台机器重建出来的东西不可比对
2. **没有 CI**：只能在有 docker 的机器上手动跑，合入前没人替你跑
3. **Docker Hub 不可达**：上游镜像全靠历史缓存续命，缓存一清栈就起不来

**已实测的关键约束**

| 事实 | 结论 |
|---|---|
| 仓库为**私有** | GHCR 包默认私有 |
| 现有 PAT 权限 | `write:packages` / `delete:packages` / `repo` / `workflow` 都有 |
| Actions | 已启用，`allowed_actions: all` |
| 到 GHCR | 可用（`ghcr.io/v2/` 401 属正常） |
| 到 Docker Hub | **不可用** → ghcr 覆盖文件是刚需 |
| 自建镜像 digest 事先未知 | 必须「先构建 → 拿 digest → 回写锁定表」，不能凭空写 |

## 范围

**新增**

| 文件 | 内容 |
|---|---|
| `.github/workflows/images.yml` | matrix 构建 `router` / `jjb` / `m0-test` 推 GHCR（`:sha-<7位>` 恒定，`:latest` 仅 main），job summary 输出 digest 表，上传 `digests.txt` artifact |
| `.github/workflows/mirror.yml` | matrix `skopeo copy --all --preserve-digests` 镜像上游；每项**校验源/目标 digest 相同**，不同则失败；`workflow_dispatch` + 每周定时 |
| `.github/workflows/test.yml` | checkout → `make test` → `make test-bats`；失败上传日志 artifact |
| `docker-compose.ghcr.yml` | 覆盖全部 `image:` 到 GHCR（上游用**同 digest**；自建镜像用 `make images-pin` 回写） |
| `scripts/pin-images.sh` | 从 GHCR 解析自建镜像 digest，回写 `docker-compose.ghcr.yml` 与 `tests/images.lock` |
| `scripts/test_ci.py` | 纯逻辑测试：workflow YAML 结构、compose 覆盖文件完整性 |
| `docs/M0-镜像与CI.md` | 流水线结构、怎么触发、怎么回写 digest、怎么用 GHCR 镜像起栈 |

**改**

| 文件 | 改法 |
|---|---|
| `Makefile` | `test-bats USE_GHCR=1`（叠加 `-f docker-compose.ghcr.yml`）、`images-pin` |
| `tests/images.sh` | 支持从 GHCR 取镜像 |
| `tests/harness/entrypoint.sh` | 支持 `M0_COMPOSE_EXTRA` 叠加 compose 文件 |
| `tests/bats/helpers/common.bash` | 配合 GHCR 模式 |
| `docs/M0-测试体系.md` | 补 GHCR 模式说明 |

**不做**

- 不做镜像签名（cosign / SLSA）——另开议题
- 不做自动部署到目标机器（M0 没有 agent）
- 不把上游镜像改成我们自己重建（只做搬运，保留原始 digest）

## 验收

- [ ] `python3 scripts/test_ci.py` → 退出码 `0`
- [ ] push 分支后 `images.yml` 三个 matrix 任务全绿（`gh api /repos/.../actions/runs` 显示 success）
- [ ] GHCR 上能查到 `router` / `jjb` / `m0-test` 与 `mirror-*` 系列
- [ ] **digest 保持验证**：`mirror-caddy` 的 digest 与 `tests/images.lock` 里 `caddy` 的 digest **完全一致**
- [ ] `test.yml` 在 PR 上跑绿
- [ ] 反证：把 `routes.yaml` 里 `nexus` 那条 route 注释掉再 push → `test.yml` **必须红**（附 run 链接）
- [ ] 反证：把某个 `mirror-*` 的 `--preserve-digests` 去掉 → `mirror.yml` 的 digest 比对**必须失败**
- [ ] `make images-pin` 执行后 `docker-compose.ghcr.yml` 里自建镜像 digest 为真实值，
      且 `docker compose -f docker-compose.yml -f docker-compose.ghcr.yml config -q` 通过
- [ ] `tests/images.lock` 里每个 digest 仍与 compose 一致（`00_stack.bats` 仍绿）

## 禁止事项

- 不得在 CI 里自动 commit 回写 digest：回写由 `make images-pin` **人工触发**，CI 只产出 artifact（否则会形成 commit 循环）
- 不得把上游镜像改成自己重建：只做搬运，digest 必须原样
- 不得把 PAT 或 `GITHUB_TOKEN` 写进任何入库文件
- 不得让 `docker-compose.ghcr.yml` 只覆盖一部分 `image:`：漏一个就会悄悄回落到 Docker Hub
- 不得自行合并 PR

## 依赖与前置

- [ ] 仓库 Actions 已启用
- [ ] 工作流权限含 `packages: write`
- [ ] `skopeo` 在 runner 上可用（`ubuntu-24.04` 自带或 apt 安装）

## 交付物

- [ ] 分支 `feat/12-ci-ghcr`
- [ ] PR 正文含：做了什么 / 三个 workflow 的结构说明 / 验收实测表 / 未验证项
- [ ] `docs/M0-镜像与CI.md` 必须写「digest 回写的三步」与「拉不到 Docker Hub 时怎么切 GHCR」

## 当年实测（PR #14 记录）

| 项 | 结果 |
|---|---|
| `images.yml` | 3 个 matrix 任务全绿 |
| GHCR 包 | `router` / `jjb` / `m0-test` + `mirror-*` 系列 |
| `mirror-caddy` digest | 与 `images.lock` 中 `caddy` 完全一致 |
| `test.yml` | PR 上绿 |
| `test_ci.py` | 通过 |

## 与本卡的偏离

- **当年是「包默认私有，拉取需 `docker login`」；现在全部改为 public**（#16）。
  `tests/images.sh` 与 `Makefile` 已去掉登录前置，并新增 `18_public.bats` 匿名可达断言。
  凭据只留在 `mirror.yml` 的**推送**侧（`skopeo login`），拉取侧一个 token 都没有
- 当年的 `test.yml` 只跑 `make test-bats`；现在是 `make identity-check` + `make test` + `make test-bats`
- 上游镜像数量从 7 个增加到 10 个（加了 `dnsmasq`、`ubuntu` 等）
