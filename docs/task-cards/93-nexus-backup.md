# [#93] REQ-M0-B5 Nexus 备份 Job + Docker / GHCR 推送配置

- **Issue**：#93（https://github.com/zeek-zhao/orgflow-devops/issues/93）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`feat/93-nexus-backup`
- **依赖**：#91（**已合并**，`7c5b773`）、#85 仓库侧（**已合并**，`155b440`）
- **token 预算**：约 12 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 2（与 #86/#87/#88 无交集：本卡只碰备份链路、Nexus Job、镜像文档）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md`、`docs/会话交接.md` §0/§3
> 与 `docs/派单流程.md`；需求编号与资料依据见 `docs/M0-增量需求总表.md` §3 REQ-M0-B5。

**本卡特别提示**：`make check-pins` 目前 RC=2（Jenkins 自定义镜像 digest 仍是占位），
那是 #90 的上线闸门遗留，与本卡无关；不要为了让它变绿而编造 sha256，也不要改 `tests/images.lock`。

## 目标

Jenkins 上有一个可参数化的 Nexus 备份 Job，备份同时覆盖数据库与 blob store 并能恢复演练；
镜像推送 GHCR 的配置与凭据路径成文、可照抄复跑。

## 背景与取证（开工前已实测，可直接引用）

| 事实 | 值 | 取证方式 |
|---|---|---|
| Nexus 后端是 **H2 MVStore**，不是 PostgreSQL | `/nexus-data/db/nexus.mv.db` | `docker exec of-nexus ls -la /nexus-data/db` |
| 制品在 blob store | `blobs/default/`，实测 85 文件 / 875 KB | `docker exec of-nexus du -sb /nexus-data/blobs` |
| **Nexus 已移出 compose（#46）** | `docker compose config --services` 里没有 nexus，容器由 `nexus-deploy.sh` 用 `docker run` 拉起，名 `of-nexus` | `docker compose config --services` |
| **备份链路当时完全不通** | `docker compose ps --status running -q nexus` → `no such service: nexus`，`backup.sh --service nexus` 在 `running_service` 处必失败 | 实测 rc=1 |
| 停写后 H2 会压缩 | 运行中 6828032 B → 停服后归档内 2076672 B | 备份前后对比 `stat` |

## 范围

**改**
- `scripts/backup-common.sh`：服务运行时抽象（`container_exists` / `running_service` / `stop_service` / `start_service`），nexus 走 docker，其余仍走 compose
- `scripts/backup.sh`：改用 `start_service`；nexus 分支加内容级门禁
- `scripts/restore.sh`：`container_exists` / `start_service` 替换 compose 直调
- `docs/备份与恢复.md` 增 Nexus 章节；`docs/M0-镜像与CI.md` 增 GHCR 推送段；`.env.example` 只加键名

**新增**
- `config/job_definitions/nexus/nexus-backup.yaml`（Job `nexus-backup`）
- `shared-library/vars/nexusBackup.groovy`
- `scripts/nexus-backup.sh`（备份 → 校验 → drill 解包核对 → boot check）
- `scripts/check_nexus_archive.py`（db + blobs 双要件判据，`--json`）
- `scripts/test_nexus_archive.py`（合成归档覆盖 7 类反证）

## 验收

- [ ] `make jobs` 后 Jenkins 出现该 Job 且参数可见（贴 job 列表 + 参数默认值）
- [ ] 触发一次备份，产出物同时含数据库导出与 blob store 归档（贴文件清单 + 大小）
- [ ] 恢复演练能读回（贴结果）
- [ ] GHCR 推送命令在文档里可直接照抄且用 `$GITHUB_TOKEN` 环境变量
- [ ] 反证：只备份数据库不备份 blob store → 校验脚本必须红；补齐后复绿

## 禁止事项

- 不得把 `GITHUB_TOKEN` 明文写进任何文件、命令行参数或日志
- 不得覆盖现有备份产物
- 不得跳过恢复演练
- 不得为了过测试放宽断言（`test_jobs.py` / `test_backup.py` 的夹具要按真实 Nexus 卷形状补，不是删断言）
- 不得自行合并 PR

## 依赖与前置

- [x] 前置 Issue #91 已合并（`7c5b773`）
- [x] 已确认 213 的 Nexus 是 **H2** 后端

## 本卡的派工边界（派单方补充）

- 在**独立 git worktree**（`/tmp/wt-93`）里工作，不改 213 主工作区、不改 `.env`。
- 备份会**真的停一次 `of-nexus`**（约 10-20 秒）再启回；这是验收要求的一部分，
  但不得顺带重启/重建其他容器，不得执行 `make down -v`。
- 恢复演练**只用独立 drill 卷**，绝不 `restore.sh --service nexus` 打生产卷。
- 提交信息符合 `docs/提交规范.md`，author 恒为 `zeek.zhao <zeek.zhao@foxmail.com>`，不带 AI 署名。
- 基线：以开工时 `origin/main` 为准（本卡落库时 = `155b440`）。

## 交付记录

（派单方填）

- 分支：`feat/93-nexus-backup`
- 执行方式：**派单方手工执行**（本卡未外派）
- 提交：见 PR
- `make test`：RC=0（新增 `test_nexus_archive.py` 12 用例；`test_job_pipelines.py` 检查 6 个 job 全绿）
- `make jobs-test`：RC=0，渲染 16 个 job（原 15 + `nexus-backup`）
- `make jobs`：RC=0，`Creating jenkins job nexus-backup`，16 个 job 全部更新
- 实跑证据：
  - 包 `nexus-20261106-174129-639810740.tgz`，**870441 B**，sha256 `5d8ef422…6a3a9c`，`files=190`
  - 内容：`db/nexus.mv.db` **2076672 B** + `blobs/default/` **85 文件 / 830352 B**
  - drill 卷：db sha256 一致（`eba581c8…`）、blobs 85 文件 / 830352 B 一致
  - boot check：临时 Nexus 20s 启动，宿主端口 32778，HTTP **200**
  - 反证：只 db → RC=1（`✗ 缺少 blob store 归档`）；只 blobs → RC=1（`✗ 缺少 db/nexus.mv.db`）；全量包 → RC=0
- 与本卡的偏离：无
