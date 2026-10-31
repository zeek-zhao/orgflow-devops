# [05] 备份与恢复（脚本 + 保留策略 + 手册）

- **Issue**：#5
- **PR**：#10
- **分支**：`feat/5-backup-restore`
- **类型**：回溯重建（原文是一段话的派单 prompt，验收口径按当前仓库状态重写）
- **依赖**：#4（`deploy.sh` 起的栈）
- **token 预算**：约 10 万 token

## 目标

把「只有单向备份」补成**可验证、可还原、可演练**的闭环。

原 `backup.sh` 只能打包，**没有任何恢复手段** —— 备份不可还原等于没有备份。终态：

- `backup.sh` 产出 `.tgz` + `.sha256` + `.meta` 三件套，**坏包不留**
- `restore.sh` 能从三件套完整恢复，默认 `--dry-run` 只打印计划
- 保留策略正确（不删本次刚生成的包；`RETENTION=0` 明确拒绝）
- 有一份能照着做的演练手册

## 背景与取证

| 事实 | 值 / 结论 | 怎么来的 |
|---|---|---|
| 对运行中的 Jenkins/Nexus 直接 `tar` 卷会得到**不一致快照** | 备份前必须 `docker compose stop <svc>`，备份完再启回 | 卷内文件在写入中，tar 会读到半截 |
| `docker volume rm` 恢复是**陷阱** | 删卷后 compose 重启会**新建空卷**，极易让人误以为恢复成功 | `docker volume rm` + `up -d` 后卷是空的 |
| `RETENTION=0` 语义危险 | 0 天 = 立刻删光，属误配置 → 必须明确拒绝 | 保留清理逻辑按天数比较 |
| LDAP 备份只含 `ldap_data` | 完整灾备还需同时保管 `ldap_config`（slapd 配置目录） | `docker volume ls \| grep ldap` → 两个卷 |
| `caddy_data` 只存证书，可重建 | 不纳入备份 | — |

## 范围

**改**

| 文件 | 改法 |
|---|---|
| `scripts/backup.sh` | 打包后立刻 `tar tzf` 完整校验，失败删包并非 0 退出；产出三件套；备份前停写；保留清理排除本次产物；新增 `--verify` |
| `scripts/backup.sh` 的保留逻辑 | `RETENTION=0` 明确报错退出 |
| `scripts/test_jobs.py` | 补 restore Job 的渲染断言 |
| `shared-library/test/stepsTest.groovy` | 补 `restoreService` 的行为测试 |
| `Makefile` | 新增 `restore` / `backup-verify`；两者必须显式传 `SERVICE` / `BACKUP_FILE` |

**新增**

| 文件 | 内容 |
|---|---|
| `scripts/backup-common.sh` | 服务↔卷映射、清单读写、脱敏等公共逻辑 |
| `scripts/restore.sh` | 完整恢复：停服 → 清空卷**内容**（保留卷本身）→ 解包 → 启回；`--dry-run` / `--force` |
| `config/job_definitions/restore/restore-service.yaml` | 参数化恢复 Job，`CONFIRM` 必须为 `YES` |
| `shared-library/vars/restoreService.groovy` | 沿用 deployService 写法（`withEnv` / `set +x` / 白名单） |
| `scripts/test_backup.py` | 纯逻辑测试，**不依赖真实 docker 卷** |
| `docs/备份与恢复.md` | 备份范围、命令速查、演练手册、失败处置、磁盘估算 |

## 验收

- [ ] `python3 scripts/test_backup.py` → 退出码 `0`
- [ ] `python3 scripts/test_jobs.py` → 退出码 `0`
- [ ] `ls .jjb/rendered/*.xml \| wc -l` → `3`（deploy / backup / restore）
- [ ] `bash -n scripts/*.sh` → 退出码 `0`
- [ ] `make backup` → 退出码 `0`，`backups/` 下出现同名三件套（`.tgz` / `.sha256` / `.meta`）
- [ ] `tar tzf backups/<最新>.tgz >/dev/null` → 退出码 `0`
- [ ] `sha256sum -c backups/<最新>.tgz.sha256` → `OK`
- [ ] `BACKUP_FILE=backups/<最新>.tgz make backup-verify` → 退出码 `0`
- [ ] `bash scripts/restore.sh --service ldap --file backups/<最新>.tgz --dry-run --force` → 打印计划，**未停服、未改卷**（前后 `docker inspect` 的 `State.StartedAt` 不变）
- [ ] 真实恢复后 `ldapsearch -b dc=devops,dc=com -s sub "(objectClass=*)" dn \| grep -c ^dn:` → `33`，容器 healthy
- [ ] 反证：把 `.tgz` 截断一半 → `make backup-verify` **非 0 退出**，且**不会**打印「校验通过」
- [ ] 反证：`RETENTION=0 make backup` → **非 0 退出**并报「保留天数为 0」
- [ ] 反证：对非空卷执行 `restore.sh` **不带** `--force` → 非 0 退出并提示需要 `--force`

## 禁止事项

- 不得用 `docker volume rm` 做恢复：会新建空卷，让人误判恢复成功
- 不得在打包后跳过 `tar tzf` 校验：**坏包不留**是这条流水线的底线
- 不得让 `RETENTION=0` 静默删光备份
- 不得把 `--no-stop` 设为默认：不一致快照比慢几秒危险得多
- 不得为了「跑得快」而在测试里连真实 docker 卷：`test_backup.py` 必须纯逻辑
- 不得自行合并 PR

## 依赖与前置

- [ ] `make deploy` 已跑过，栈 healthy
- [ ] 可用磁盘 ≥ 2 × 备份体积
- [ ] `tar` / `sha256sum` 可用

## 交付物

- [ ] 分支 `feat/5-backup-restore`
- [ ] PR 正文含：做了什么 / 关键设计（坏包不留 / 不用 `volume rm` / 双重护栏） / 验收实测表 / 已知边界
- [ ] `docs/备份与恢复.md` 必须写明「LDAP 备份只含 `ldap_data`，完整灾备还要保管 `ldap_config`」

## 当年实测（PR #10 记录）

| 项 | 结果 |
|---|---|
| `test_backup.py` | 15/15 |
| 回归 | router 14 / bootstrap 6 / jobs 11 / deploy 9 全过 |
| `make jobs-test` | 渲染 3 个 Job（deploy / backup / restore） |
| 真实备份 | 产出三件套 |
| `backup.sh --verify` | 校验通过 |
| `restore.sh --dry-run` | 计划正确，未停服、未改卷 |
| `restore.sh --force` 实恢复 | LDAP 恢复后仍 33 条，容器 healthy |
| 保留策略 | 过期假包被清理，本次三件套保留 |

## 已知边界（当年已写进手册）

- LDAP 备份只含 `ldap_data`；完整灾备还需同时保管 `ldap_config`
- `caddy_data` 只存证书，可重建，不纳入备份
- 非空卷的 `--dry-run` 也需要 `--force`（dry-run 也走同一套安全检查）

## 与本卡的偏离

无。本议题的实现至今未因 ADR-13 变更。
