# Changelog

本文件记录 orgflow-devops（M0 最小 DevOps 底座 + M1 Jenkins）的版本变更。格式遵循「保持一个版本一段、新增在上」的轻量约定。

## [m3.0.3-manual-drill] — 2026-11-28（手动演练、不设长定时器）

> 基线 `m3.0.2-backup-truth`（tag 指 `7016ae1`），分支 `feat/m2-gerrit-cgit-harbor`，**不合并 main**，旧 tag 不移动。依据《OrgFlow M3.0.3 施工提示词（修订版）：手动演练、不设长定时器》。逐条实测见 `docs/records/执行日志/2026-11-28.md` 的 M3.0.3 小节。核心：撤销 M3.0.2 引入的自动调度（drill 周日跑、backup 03:30），改纯手动 + `up.sh` 启动时一次性补跑。硬约束：不新增任何 >5 分钟定时器、不新增"睡到固定时刻"的常驻守护；服务随时可能被关停，任何依赖"昨夜已跑过"的设计不可靠。
>
> - **T1 删除演练常驻、改纯手动（E1）**：删 `deploy/supervisor/orgflow-drill.conf`、`scripts/drill-daemon.sh`、`scripts/drill-watchdog.sh`；Makefile 新增 `drill`（前台跑 `drill-up.sh`，输出 DRILL PASS/FAIL、退出码即结果，不注册调度），移除 `drill-now`/`drill-daemon-install`/`drill-daemon-status`；`verify-restore-drill` Job DSL 删 `triggers { cron(...) }`。验收：supervisor/ps 无 orgflow-drill/drill-daemon、全仓库无 04:00 演练调度残留。
> - **T2 去新鲜度判红、去 data-drill 默认项（E1）**：`verify-restore-drill.Jenkinsfile` 删"≤26h"判红改打印 `age_h` 信息字段（缺失/FAIL 仍 FAILURE 并提示"请先 make drill"），断言字段化（`result=PASS`/`healthy=3`/`repos=3`/`P_open=D_open`/`P_total=D_total`/`backup_sha256` 与 manifest 一致/`mode∈{quick,full}`，不 grep 中文文案 E5）；`checks.tsv` 删 data-drill 行（自检恢复 21 项报告口径 / tsv 22 行），`check-selfcheck.sh` 项数改 22 行、断言无 data-drill、豁免 verify-restore-drill 反向登记。演练结果改由封版清单人工把关。
> - **T3 生产 changes 硬失败、双指标（E3）**：`drill-up.sh` SSH 显式捕获退出码，私钥缺失/SSH 非 0/输出空/解析非数字直接 `ssh-key-missing` FAIL，绝不当 0；双指标 `P_open/D_open` 与 `P_total/D_total`（total 用 `gerrit query --format=JSON 'status:open OR status:merged OR status:abandoned'`）；命令/rc/四数值写日志与 `drill.result` 字段。
> - **T4 LDAP 口令闭环（E4）**：`drill-up.sh` 的 `ldapwhoami` 用 `docker exec -e LDAP_BIND_PW=` 注入已读口令（命令内无字面口令），校验容器内 `LDAP_ADMIN_PASSWORD` 一致否则 FAIL；`deploy/drill/compose.yml` 删 `:-change-me` 兜底改 `:?` 必填（缺失 compose 直接报错）。
> - **T5 备份去 03:30 长定时（E2）**：删 `deploy/supervisor/orgflow-backup.conf`、`scripts/backup-watchdog.sh`，`backup-daemon.sh` 去 `run` 常驻模式（只留 once/rotate/status/simulate）；`up.sh` 全部 healthy 后同步检查 `/data/backups/latest` 年龄（>26h 或缺失 → 前台跑一次 `backup.sh`，日志 `[up] 启动补跑备份`），一次性动作非定时器；Makefile backup 类全手动；data-backup 自检项保留（≤26h 仍判红，因 up 启动已补跑）。
> - **T6 清遗留长定时**：`verify-gerrit-review-flow` 的 `cron('H 3 * * *')`、`verify-service`/`verify-lan-all` 的 `cron('H 2 * * *')` 全删（理由同演练：关停后夜间定时无意义且留未观测记录）；全仓库复查 cron/OnUnitActiveSec/OnCalendar，>5min 或每日固定时刻一律删/改手动。保留 quota watchdog 与 backup 状态巡检等 10s~5min 短周期。
> - **T7 收口**：更新备份与恢复（手动演练/启动补跑/发布检查表）、自检框架（21 项/无 data-drill）、CHANGELOG、执行日志 M3.0.3 六列回报 + 验收总表 + 反证输出。
>
> **不做**：备份外送、告警外发、监控组件、多环境、任何自动调度。

## [m3.0.2-backup-truth] — 2026-11-28（把备份可信做实）

> 基线 `m3.0.1-backup-trust`（tag 指 `e82dab0`），分支 `feat/m2-gerrit-cgit-harbor`，**不合并 main**，旧 tag（`m2-v1.0`/`m3.0-reliability`/`m3.0.1-backup-trust`）不移动。依据《OrgFlow M3.0.2 施工提示词：把备份可信做实》。逐条实测见 `docs/records/执行日志/2026-11-28.md` 的 M3.0.2 小节。本轮只修缺陷与补强，不扩范围、不引入新组件、不改端口/Funnel/域名/routes。
>
> - **T1 修 tar 重试（D1）**：`scripts/backup.sh` 每次 tar 尝试前显式 `rc=0`，两次都非 0 才失败；attempts + 两次退出码写入 `.tar-warnings.log`（保留审计）；注入 `BACKUP_TAR_FAIL_ONCE=1`（第一次 rc=1、第二次 rc=0）、`BACKUP_TAR_ALWAYS_FAIL=1`（两次都失败）。验收：FAIL_ONCE 整轮 `exit_code=0` 且日志含 `attempt=1 rc=1`/`attempt=2 rc=0`；ALWAYS_FAIL 整轮失败、latest 不指向残缺目录。
> - **T2 校验判红（D2）**：`backup-daemon.sh` 顺序改为"写 status 初值 → 跑 verify → 按结果回写"，捕获 `backup-verify.sh` 返回码，非 0 记 `exit_code=7` + `status.verify.ok=false`/`failures`，日志 `verify failed` 保留现场、不打印"一轮备份完成"；`backup.sh` 保持单一真源；`verify-backup.Jenkinsfile` 增断言 e（`verify.ok=true` 且 `failures` 为空）。反证：截断 gerrit pack → verify FAIL（含 git-fsck）；status 污染 → verify-backup FAILURE + selfcheck data-backup 红。恢复后 verify-backup #15 SUCCESS（五项断言全过）。
> - **T3 周备本地时区（D3）**：`backup-daemon.sh` 的 `local_day()` 把备份 UTC 时间戳转 Asia/Shanghai 取本地日期与 `%u`；`weekly.flag` 写 `local_date`/`weekday`/`backup_ts`；`manifest.json` 增 `local_date`/`weekday`；轮转校验 marker，`weekday=7` 且字段齐全才归周备，坏 marker `skip invalid marker` 不删不归类。验收：UTC `20261129T163000Z`→本地周一、`20261129T153000Z`→本地周日；5 周日留 4、日备仍 7。
> - **T4 drill 每周自动跑（D4）**：新增 `scripts/drill-daemon.sh`（常驻，下个本地周日 04:00 执行 drill-up，启动补跑 >26h；pidfile+flock，sleep 关锁 fd）、`scripts/drill-watchdog.sh`（云 IDE supervisor 不自愈兜底，每 10s 巡检拉起）、`deploy/supervisor/orgflow-drill.conf`（`orgflow-drill` + watchdog）、Makefile `drill-now`/`drill-daemon-install`/`drill-daemon-status`；`drill.result` 改 JSON；`verify-restore-drill` 新鲜度 8d→26h + result.ts/日志同源≤10min + JSON 可解析。反证 #15（ts 改坏不同源）/ #16（30h 过期）FAILURE；正向 #14/#17 SUCCESS。
> - **T5 drill 断言补强（D5）**：`drill-up.sh` 强制 healthy=3；changes 与生产实时对比 P==D（P 取不到直接 FAIL、不默认 0）；LDAP 口令从 `LDAP_PASSWORD` 环境或 `/opt/orgflow/secrets/ldap_admin_password` 读（禁硬编码，创建 600 权限口令文件）；Gerrit 镜像 tag 从 `config/images.env` 的 `IMAGE_GERRIT` 解析（禁硬编码）；cgit HTTP 200 重试 5 次；起栈前只 `docker compose down -v` 清残留（不调 `drill-down.sh`，否则删解包数据致 server_id 丢失）；server_id 从生产 etc 卷复制到解包 etc。`verify-restore-drill` 增日志断言行解析（P==D + healthy=3）。正向 DRILL PASS（healthy=3、cgit 200、gerrit 3.9.0、P=0 D=0、ldap rc=0、174s）。
> - **T6 报告同源真校验（D6）**：`selfcheck` 新增 `deployTag`（`git describe --tags --exact-match HEAD`，无则 `none`）与 `tagCommit`（tag 指向 SHA，无则 `unknown`），`consistent=commit==tagCommit && tagCommit!='unknown'`；报告顶部显示 commit/tag/consistent 三行；`verify-status-page` 断言三字段齐全 + consistent=YES + commit==tagCommit；`check-selfcheck.sh` 5g 门禁。反证：旧 checkout（HEAD 无 tag）→ `consistent=NO`；正向：tag `m3.0.2-backup-truth` 提交上 → `consistent=YES`、`deployTag` 正确。
> - **T7 清理与收口（D7）**：清理执行日志"index 匿名卷每次必须 reindex"旧结论（改为"named volume 根治、仅卷丢失才需 reindex"）；更新备份与恢复/自检框架文档口径；`checks.tsv` 描述更新（data-backup 加 verify.ok、data-drill 加 JSON/同源/26h）。
>
> **门禁**：`make check`/`make test` 全绿；真校验在旧 checkout 判 NO、在 tag 提交判 YES。

## [m3.0.1-backup-trust] — 2026-11-28（让备份变成可信灾备）

> 基线 `m3.0-reliability`（tag 指 `46665af`），分支 `feat/m2-gerrit-cgit-harbor`，**不合并 main**，旧 tag（`m2-v1.0`/`m3.0-reliability`）不移动。依据《OrgFlow M3.0.1 施工提示词：让备份变成"可信灾备"》。依据文档口径实测见 `docs/records/执行日志/2026-11-28.md` 的 M3.0.1 小节与三份运维文档。
>
> - **T1 备份定时化**：`scripts/backup-daemon.sh`（03:30 常驻 + 26h 补跑 + flock/pidfile 单实例 + 水位>85% exit_code=5 + 日备7/周备4 轮转 + status.json 全字段）；`deploy/supervisor/orgflow-backup.conf`（+ watchdog 兜底，云 IDE supervisor autorestart 不触发）；`deploy/systemd/orgflow-backup.{service,timer}`；`backup.sh` 加 `--warning=no-file-changed` + 退出码1重试 + `changed_during_backup`。验收：supervisor RUNNING、kill -9 后 9s 拉起新 PID、FAKE_NOW 9 日轮转稳定7、5 周备留4、水位跳过 exit_code=5、真实备份 status 全字段 exit=0。
> - **T2 接入自检**：`verify-backup` Job（四项断言 latest≤26h/sha256/manifest 9卷/status=0，jq+shell，无 python3）；checks.tsv + data-backup、check-selfcheck.sh 5f 门禁。反证 #5 过期/#6 tar 损坏/#7 status≠0 全 FAILURE，恢复 #8 SUCCESS。项数口径：文档按旧 20→21，实际 M2.5.5 已 21 项，本轮加后 **22 项**；Job 23→24。
> - **T3 隔离恢复真起栈**：`scripts/drill-up.sh`/`drill-down.sh` + `deploy/drill/compose.yml`（独立 project `orgflow-drill`、网络 172.31.90.0/24、起 gerrit/cgit/ldap 三容器、quota 守卫 PASS 才起、reindex 到 bind index）；`verify-restore-drill` Job（cron H 4 * * 0，离线只读结果）。DRILL PASS 四项断言全过、172s<10min、三容器 healthy、生产不受影响；反证删 pack → git fsck 指出缺失仓库 + Job #2 FAILURE；Job 24→25，自检 22→23。
> - **T4 报告与代码同源**：selfcheck commit 取 Pipeline git rev-parse HEAD（全 SHA），latest.json 加 `deployedHead`/`consistent` 字段 + 报告顶部两行；verify-status-page 加同源断言。全量 selfcheck #26 PASS（commit=deployedHead=283a3ed，consistent=YES），反证旧 commit 报告 → #21 FAILURE、恢复 #22 SUCCESS。
> - **T5 热备一致性**：`backup-verify.sh` 加 git fsck --no-dangling（白名单 Gerrit meta HEAD 误报）+ Jenkins XML 解析 + status.json.verify 字段；正常 verify 全过，截断 pack 反证 FAIL。
> - **T6 Gerrit index named volume**：`services/gerrit/compose.yml` 加 `gerrit_index` external volume（up.sh 预建、defaults.env 定义），`scripts/gerrit-index-migrate.sh` 停 gerrit→建卷→root 容器 cp -a 旧 index（26 文件）→起 gerrit（未手工 reindex）；两次 force-recreate 62/66s healthy（≤90s）、open changes 前后=0、端到端 #13 SUCCESS（change 81）。根治 M3.0 遗留的"匿名卷每次换卷需 reindex"。
> - **口径偏差说明**：沙箱云 IDE supervisor 的 RPC 对动态 program 的 autorestart 实测不触发 → 备份守护与 quota 同机制加 watchdog（nohup 常驻）兜底；agent 无 docker.sock → verify-restore-drill 采用离线只读结果（同 T4「隔离起栈内存不足改离线校验」口径）。
>
> **门禁**：`make check`/`make test` 全绿；selfcheck 全量 #26 PASS（FAIL=0 SKIP=0，commit 等于头）。

## [m3.0-reliability] — 2026-11-28（可靠性与灾备）

> 基线 `m2-v1.0`（a553a9e），分支 `feat/m2-gerrit-cgit-harbor`，**不合并 main**。依据《OrgFlow M3 规划与 M3.0 施工提示词：可靠性与灾备先行》。零代码逻辑改动，只加脚本与文档；实测见 `docs/records/执行日志/2026-11-28.md` 与 `docs/运维/备份与恢复.md` §6、容量与清理.md §5。
>
> - **基线采集**：磁盘 39%、23 镜像 3.6GB、52 卷 640MB、12 容器 healthy；9 个必备卷与大小盘点。
> - **备份脚本**：`scripts/backup.sh` + `make backup`（9 卷 tar+sha256+manifest → `/data/backups/<UTC>`）；`scripts/backup-verify.sh` + `make backup-verify`（sha256 + 逐卷解包 + 条目数）。连续两次备份成功、两次 verify 全通过（9 卷/7692 条目）。
> - **恢复脚本**：`scripts/restore.sh` + `make restore`（解包到隔离目录，逐项比对 Gerrit 仓库数/registry digest/Jenkins Job 数）。隔离演练：3 库 / 2 digest / 23 Job，数量+名单与生产一致。
> - **容量清理**：`scripts/disk-report.sh` + `make disk-report`；`scripts/prune-images.sh` + `make prune-images`（CONFIRM=1 实际清 dangling，保留在用 tag）。实测回收 97.23MB。
> - **全量重建演练**：暂停 cron → 备份校验 → `./down.sh`（保留卷）→ `./up.sh --no-pull` → `scripts/gerrit-reindex.sh` + `make gerrit-reindex`（匿名 index 卷重建必做）→ 恢复 cron。13 步 healthy，总耗时 ≈27 分钟（窗口内）。
> - **重建后验收**：自检 #24 PASS（FAIL=0 SKIP=0，mechanism=supervisor）；端到端 change #61 → Verified +1 → abandon → open=0；入口 7 路径符合预期。
> - **发现与遗留**：Gerrit index 是匿名卷，每次 down+up 换新空卷需 reindex（已用 `make gerrit-reindex` 固化为补救步骤）；镜像 tag 漂移（配置期望 `m2-gerrit:ctx-547cec6a8cd0`，线上原 `3.9.0`）；根治方案（index/db/cache 改 named volume）与备份外送留到 M3.1 评估。
> - **文档**：`docs/运维/备份与恢复.md`（§6 自动化 + 演练记录）、`docs/运维/容量与清理.md`（新建）、执行日志 2026-11-28 M3.0 小节。

## [m2-v1.0] — 2026-11-27（M2 封版：自检可信度 + 全量终验通过）

> 分支 `feat/m2-gerrit-cgit-harbor`，annotated tag `m2-v1.0` 指向封版提交（含 M2.5.5 自检可信度修复）。**分支保持不合并 main**。依据《OrgFlow M2.5.5 自检可信度修复与 M2 封版收口 · AI 提示词》。本段汇总 M2.1~M2.5.5 全量条目；每步实测见 `docs/records/` 执行日志与封版记录 `docs/records/M2-封版记录.md`。
>
> **M2 全量条目（按里程碑）**：
> - **M2.1 `m2.1-v1.0`**：Gerrit + cgit 上线，评审流 4/4 通过（change→build→Verified→push）。
> - **M2.2 `m2.2-registry` / `m2.2-registry-p0`**：registry 上线 + 公网强口令、清测试仓。
> - **M2.3 `m2.3-gerrit-ci` / `m2.3-closeout`**：Gerrit→Jenkins 触发链（patchset-created → build-from-gerrit）、判据 C 闭环、失败不回写 Verified、P2 收口。
> - **M2.4 `m2.4-selfcheck` / `m2.4-phase3`**：自检框架（20 项清单 + HTML/JSON 报告）、Gerrit 人工手册、每服务 Dockerfile、Phase0/1 门禁。
> - **M2.5 `m2.5-quota-guard`**：构建资源四项铁律（宿主全资源 + 容器零限制证据）+ M2.4 复核缺陷收口。
> - **M2.5.1 `m2.5.1-quota-lifecycle`**：配额证据生命周期加固（preflight/compare + age 校验）+ 端到端验证。
> - **M2.5.2 `m2.5.2-quota-refresh`**：自动刷新修复（cron/systemd/supervisor/runit/nohup 多路径 + 反证）。
> - **M2.5.3 `m2.5.3-quota-supervision`**：刷新机制服务化（supervisor + watchdog）+ 存活校验 + 收尾一致性。
> - **M2.5.4 `m2.5.4-quota-single-instance`**：刷新单实例保证（trap 只删自己 pidfile + 全局计数 + 条件 watchdog）+ 安装可移植性（supervisor-conf-dir.sh）+ 报告口径统一（result/overall）。
> - **M2.5.5 `m2.5.5-selfcheck-trust`**：自检可信度修复（pidfile 心跳续约、构建结果回写、机制分支判据、heavy 定时、mechanism 独立来源）——见下段。
>
> **封版终验（7 条全过）**：① 两次全量自检连续全绿、commit 相同；② 反证三连（证据过期 BLOCKED/Verified 空、机制死亡红、双实例红）恢复后各自转绿；③ 端到端 change→40s 触发→BUILD QUOTA OK→push→Verified+1→abandon→open=0；④ 入口矩阵 7 路径符合预期；⑤ 三份文档与现状一致；⑥ tag `m2-v1.0` annotated 指向封版提交并 ls-remote 核验；⑦ 分支不合并 main。可选的全量拆除重建未做，在封版记录显式标注"基于增量验证"。

## [m2.5.5-selfcheck-trust] — 2026-11-27（自检可信度修复）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `2b841ae`（tag `m2.5.4-quota-single-instance`）。依据《OrgFlow M2.5.5 自检可信度与 M2 封版 · AI 提示词》。修三处自检可信度问题 + 补一个被文档声称存在但没落地的定时任务。详见 `docs/records/执行日志/2026-11-27.md` 的 `### m2.5.5` 小节。
- **P0-1 pidfile 心跳续约**：`refresh_loop()` 每轮 `echo $$ > daemon.pid`（删后 ≤5min 自愈）；`make quota-cleanup-nohup` 仅 `instances==0` 才删 pidfile；启动时 pidfile 指向别的存活 loop → `exit 4` 拒绝双实例。实测 kill -9 后新 PID 29224 + pidfile 重建 + `pidfile_pid==pid`。
- **P0-2 构建结果回写**：`selfcheck` 总判 FAIL → `currentBuild.result=FAILURE`，PASS → SUCCESS，与 description 同口径。反证 `NEGATIVE=true` → `Finished: FAILURE`，恢复 → SUCCESS（#18 PASS / #19 FAILURE / #20 PASS）。
- **P1-1 机制分支判据**：`verify-quota-refresh` 按 mechanism 分支——常驻（supervisor/runit/nohup）校 `instances==1 && pidfile_pid==pid && alive≤8min`；瞬时（cron/systemd-timer）跳过 pidfile、改心跳≤10min；none/unknown FAIL。反证 pidfile_pid=0 / instances=2 均红、恢复绿。
- **P1-2 heavy 定时**：`verify-gerrit-review-flow.groovy` 加 `cron('H 3 * * *')`（logRotator 原有）；config.xml 含 TimerTrigger spec；手动 #10 SUCCESS（change #57 → Verified +1 → abandon → open=0）。
- **P2-1 mechanism 独立来源**：报告 mechanism 优先读 `mechanism.txt` → `alive.json.mechanism` → unknown，不再从 FAIL 行 description 提取。
- 封版终验全过；tag `m2.5.5-selfcheck-trust` 与封版 `m2-v1.0` 均推送。

## [m2.5.4-quota-single-instance] — 2026-11-27（刷新单实例保证与安装可移植性）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `6a39aed`（tag `m2.5.3-quota-supervision`）。依据《OrgFlow M2.5.4 刷新单实例保证与安装可移植性 · AI 提示词》。不改动 M2.5.3 已验证的刷新/判定主链路与阈值，只补三类"换机或重启会炸"的问题。详见 `docs/records/执行日志/2026-11-27.md` 的 `### m2.5.4` 小节。
- **P0-1 单实例保证**：loop EXIT trap 只删自己的 pidfile（比对 `$$`）；watchdog 拉起前全局实例判断（`/proc` 精确计数，>0 跳过）；conf 中 watchdog 改 `autostart=__WATCHDOG_AUTOSTART__`，`make quota-supervisor-install WATCHDOG=0`（默认/真机，原生 autorestart 不双实例）/ `WATCHDOG=1`（沙箱）渲染。实测 kill -9 后 15s 只拉起 1 个新 PID。
- **P0-2 双实例可观测**：`write_alive` 增 `instances`/`pidfile_pid`；`verify-quota-refresh` 增判据 `instances==1 && pidfile_pid==pid`（否则 FAILURE + ps 列表）；报告 evidence 含 `instances=1`；`quota-status` 的 supervisor state 可见。反证 verify #9 SUCCESS → #10 FAILURE(instances=2) → #11 SUCCESS。
- **P1-1 安装可移植性**：新增 `scripts/supervisor-conf-dir.sh`（显式参数 → supervisorctl 默认 → 读 include → exit 2，禁止静默落 `/usr/local/share/supervisor`）；装后强制 RUNNING 断言（失败 exit 2）；`supervisor-rpc.py` socket 必填 + shebang 改 `#!/usr/bin/env python3`。
- **P2-1 报告口径**：`buildJson` 同时输出 `result`/`overall`（同值），HTML 仍用 overall；门禁断言字段齐全。
- 全量门禁全绿；自检 20 项全 SUCCESS；端到端 change→build SUCCESS、Verified +1、open=0；tag `m2.5.4-quota-single-instance`。

## [m2.5.3-quota-supervision] — 2026-11-27（刷新机制服务化与收尾一致性）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `65a7639`（tag `m2.5.2-quota-refresh`）。依据《OrgFlow M2.5.3 刷新机制服务化与收尾一致性 · AI 提示词》。不重做 M2.5.2 已验证的刷新/反证/端到端，只补三类随时间劣化的问题。详见 `docs/records/执行日志/2026-11-27.md` 的 `### m2.5.3` 小节。

### P0 服务化与存活可观测
- **P0-1 服务化**：新增 `scripts/quota-guard-loop.sh`（统一循环：每 300s 刷新 + 日志 >1MB 自轮转 + 写 `alive.json`），三种管理器与 nohup 统一调用，刷新命令不再散落 Makefile。新增 `deploy/supervisor/orgflow-quota.conf`（`[program:orgflow-quota]` autorestart + `[program:orgflow-quota-watchdog]` 10s 巡检兜底）、`deploy/runit/orgflow-quota/run`；Makefile 增 `quota-supervisor-install`/`quota-runit-install`/`quota-cleanup-nohup`，`quota-daemon-install` 降为最后兜底并标明优先级 timer→cron→supervisor/runit→nohup。无 supervisorctl CLI 时用 `scripts/supervisor-rpc.py`（XML-RPC）管理。装服务前按 daemon.pid + 命令行精确清旧进程，禁止双写。实测 kill -9 loop 后 15s 内 watchdog 拉起新 PID。
- **P0-2 存活校验**：`ci/selfcheck/checks.tsv` 增 `guard-quota-alive`（自检 20→21 项），新增 `verify-quota-refresh` Job + Jenkinsfile，校验三判据（进程命令行匹配 + 日志新鲜≤8min + 证据 age≤10min），任一失败 FAILURE 红行。selfcheck 报告 meta 增 `mechanism=` 字段（取自 alive Job description）。`quota-status.sh` 输出 `mechanism=` 并校验声明与进程一致。

### P1 真机坑与长期运行
- **P1-1 cron 语法**：新增 `deploy/cron/orgflow-quota.cron.d`（6 字段含 root），`quota-cron-install` 按分支选模板（用户 crontab 5 字段 / cron.d 6 字段），安装后 `awk 'NF>=6 && $1!="#"'` 校验，文档明确两者不可混用。
- **P1-2 日志轮转**：`quota-guard-loop.sh` 内置 >1MB 自轮转（保留 1 份 `.1`），另附 `deploy/logrotate/orgflow-quota` 供真机二选一；实测造 >1MB 假日志被切分且新日志继续写入 6 行。

### P2 一致性收尾
- **P2-1 tag 口径**：执行日志加注——tag `m2.5.2-quota-refresh` 覆盖含证据文档的 `65a7639`（功能提交 `9173783`），`git rev-list -n1` 对得上，消除"日志说 A 仓库是 B"。
- **P2-2 result 字段**：`quota-guard.sh` 写总体 `result`（PASS/FAIL/WARN，与 verdict 同口径），`check-selfcheck.sh` 增静态断言，`make quota-status` 展示 result；机器消费者 `curl latest.json | jq .result` 不再得到 null。
- **P2-3 abandoned 策略**：`docs/运维/自检框架.md` 写明"保留最近 5 条含成功+负例样本、其余按季度清理"，列出 Gerrit 查询/清理命令，历史证据链锚点不清理。

### 门禁与终验
- `make check`/`check-all`/`test` 全绿；自检 21 项全 SUCCESS 含 `guard-quota-alive` 且报告 meta 含 mechanism；反证（篡 ts 2h→FAILURE→自动刷新→SUCCESS）与端到端（真 change→SUCCESS+Verified +1→abandon、open=0）各重跑一次；线上入口 5 路径 200 / 8443 200 / 10000/v2 401；annotated tag `m2.5.3-quota-supervision` 推送可见。

## [m2.5.2-quota-refresh] — 2026-11-27（配额证据自动刷新修复）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `c3a7dc6`（tag `m2.5.1-quota-lifecycle`）。依据《OrgFlow M2.5.2 配额证据自动刷新修复 · AI 提示词》。只让刷新真正跑起来并留证，不碰判定逻辑/阈值。详见 `docs/records/执行日志/2026-11-27.md` 的 `### m2.5.2` 小节。

- **根因**：PID1=supervisord，`/run/systemd/system` 不存在 → systemd timer 物理不可用；证据 ts 停在 `06:41:53Z`，推任何 change 必被 Quota gate 以 stale 拦下。非判定逻辑缺陷，是刷新机制未运行。
- **双路径刷新**：新增 `deploy/cron/orgflow-quota.cron` + `make quota-cron-install`（优先用户 crontab，无 crontab 命令则写 `/etc/cron.d/orgflow-quota`，先去重）；`make quota-daemon-install` 作最后兜底（nohup while 循环，pidfile 防双写）。`scripts/quota-status.sh` 增强识别 cron/daemon 行，三路径均无则明确提示"无任何自动刷新机制"。
- **本沙箱实测**：cron daemon 进程在但不扫描 `/etc/cron.d`（探针经 SIGHUP 重载仍未命中）→ 启用 daemon 兜底，PID 写 `artifacts/quota/daemon.pid`，首刷验证 ts 前进 + 四行 `[quota]`+ verdict=PASS，选择理由写执行日志。
- **小账**：① `deploy/systemd/orgflow-quota.{service,timer}` 的 `Documentation=file:` 由写死 `/opt/orgflow/repo` 改 `__REPO__` 占位符，Makefile `quota-install` 的 sed 一并渲染 timer；② abandoned change 18 条，保留最近样本 #48~#52 + 历史证据链 #24/#25，清理策略写执行日志（不删历史链）。
- **验收**：15 分钟观察 ts 前进 ≥2 次、age≤6min；反证篡 ts 2h→verify FAILURE→等自动刷新→SUCCESS；真实 change 端到端 SUCCESS + Verified +1（age 来自自动刷新、非手动）；门禁全绿；tag `m2.5.2-quota-refresh` 推送可见。

## [m2.5.1-quota-lifecycle] — 2026-11-27（M2.5 复核收口：配额证据生命周期）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `4004f02`（tag `m2.5-quota-guard`）。依据《OrgFlow M2.5 复核与下一轮 AI 提示文档》。只修复与验证，不开新功能。详见 `docs/records/执行日志/2026-11-27.md`。

### P0 配额证据生命周期
- **P0-1 自动刷新**：新增 `deploy/systemd/orgflow-quota.service` + `.timer`（`OnBootSec=2min`/`OnUnitActiveSec=5min`/`Persistent=true`）；`make quota-install`（sed 替换 `__REPO__` → 安装 `/etc/systemd/system` → daemon-reload → enable --now，非 systemd 主机优雅提示）；`make quota-status` → `scripts/quota-status.sh`（timer 状态 + `latest-of-builder.json` 的 ts/age，age>10min 非 0）。证据生命周期 10 分钟、timer 每 5 分钟刷新、部署后先 quota-status 再推代码、agent 绝不挂 docker.sock 写入文档。
- **P0-2 端到端验证**（真实 Gerrit change + build-from-gerrit）：正例 #48→build#14 SUCCESS+Verified+1；负例 CPU `docker update --cpus 2` #49→#15 BLOCKED+Verified 空；负例内存 `--memory 4g` #50→#16 BLOCKED+Verified 空；恢复（重建 of-builder 清限制）#51→#17 SUCCESS+Verified+1；负例证据过期（ts 改 1h 前）#52→#18 `stale=60min` BLOCKED+Verified 空。五条 change 全部 abandon，open 归零。

### P1 证据隔离与空参数
- **P1-1 latest 覆盖**：`quota-guard.sh` 每次写 `latest-<container>.json`（门禁固定读 `latest-of-builder.json`）+ `latest.json`（仅人类查看副本）+ `<UTC>-<container>.json`；build-from-gerrit 与 verify-quota-guard 均改读 `latest-of-builder.json`。反证：`up.sh --only jenkins-agent` 不再覆盖 builder 证据。
- **P1-2 空参数**：删除 `--max-age-min`（脚本从不使用，新鲜度属消费端职责）；`--help` 与文档写明，不留半成品。

### P2 启动顺序 / 自检口径 / 部署顺序
- **P2-1 两段式**：`up.sh` 对 builder/jenkins-agent 启动**前**跑 `quota-guard.sh --preflight`（宿主三项 + docker 未限权，落 `host-preflight.json`），启动后跑 `--compare-preflight` 完整取证并比对启动前后宿主值，不一致即 BLOCKED。实测重建 of-builder 全程 PASS。
- **P2-2 自检口径**：`verify-quota-guard` 输出 `age` 字段，age>10min 时本 Job 仍 SUCCESS 但在 description 写 `QUOTA_WARN ...`（不判 FAIL）；selfcheck 报告据此把该行标 WARN（橙色）并在顶部注明"真实构建将被 Quota gate 拦"。实测 FRESH→`QUOTA_FRESH age=0min`、过期→`QUOTA_WARN age=60min`、报告新增 `warn`/`quotaWarnNote` 字段。
- **P2-3 部署顺序**：升级与回滚.md 与构建资源配额.md 写明 `git pull → make check → up.sh --recreate/--pull → make quota-guard → 再推代码`，报告 commit 必须等于部署 commit。

### 门禁与终验
- `make check` / `check-all` / `test` 全绿；22 Job（JCasC reload 生效）；selfcheck 报告 commit=新头、含 WARN 口径字段；证据 zh-new PASS 新鲜；12/12 容器 healthy；open change=0。

## [m2.5-quota-guard] — 2026-11-27（M2 封版：构建资源铁律 + M2.4 复核缺陷收口）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `f0084b2`（tag `m2.4-selfcheck`）。依据《OrgFlow M2.5 施工文档》。本轮只做修复与加固，不开新功能。详见 `docs/records/执行日志/2026-11-27.md` 与 `docs/运维/构建资源配额.md`。

### P0 构建资源铁律
- 新增 `scripts/quota-guard.sh`：采集 nproc / MemTotal(kB) / docker info NCPU+MemTotal / docker inspect NanoCpus+Memory+CpuQuota 四项；7 条判据（NCPU==nproc、MemTotal 偏差≤1%、三项配额精确 0、落盘证据、新鲜度≤10min）；退出码 0=PASS/2=BLOCKED/3=环境不可用；固定 `[quota]` 行 stdout + JSON 证据（`<UTC>-<container>.json` + `latest.json`）。不读 .env 配额变量。
- 三处接入点：① `up.sh` 在 builder/jenkins-agent 启动后落证据、不满足即 BLOCKED 非 0 中止；② `build-from-gerrit` 新增 `stage('Quota gate')`（jq 只读 latest.json，断言 verdict/container/ts 新鲜度/三项原值，不满足 `BUILD BLOCKED` 不 build 不回写）；③ `artifacts/quota` 只读挂进 controller+agent `/opt/orgflow/quota:ro`，agent 依旧无 docker.sock。
- 新增 `verify-quota-guard` 功能级 Job（只读证据、无 docker.sock）+ checks.tsv `guard-quota` 行（自检 19→20 项）；`make quota-guard` 入口；`docs/运维/构建资源配额.md`（已登记 docs/README.md DOC-E-011）。

### P1 复核缺陷
- P1-1（Dockerfile 真被引用）：gerrit/certs-init compose 改引用本服务 `ctx-` tag；CI `build-images.yml` 矩阵加 m2-gerrit/m1-certs-init（`mirror-m2.yml` 裸 3.9.0 仅作 FROM 基底兜底）；`check-images.sh` HASHED 增加 gerrit+certs-init；`tests/images.lock` 两行改 imageId=- 回填 contextSha256、删"复用 router"注释；`check-dockerfiles.sh` 增"有 Dockerfile 必引用本服务镜像"断言（EXEMPT 只 _template）。
- P1-2（去写死域名）：`verify-gerrit-review-flow` 与 `gerrit-abandon.sh` 的 canonical host 改从 `defaults.env` 的 `PUBLIC_HOST` 读取，取不到 fail，禁止静默回退字面域名。
- P1-3（报告快照失真）：selfcheck 报告 commit 改 `git -C /opt/orgflow/repo`（repo 根只读挂 controller，取不到写 unknown+warning）；Jenkins 版本 jenkins.version→war MANIFEST→unknown；镜像改输出 `键=值` 并单独列"镜像 tag"表；加 `heavyNote`（heavy 未纳入本轮）。

### P2 加固
- P2-1：`check-selfcheck.sh` 反向校验从 `grep -qF` 子串匹配改第 3 列整字段相等（`verify-cgit` 不再被 `verify-cgit-smart-http` 顶替）。
- P2-2：selfcheck 的 `EXCLUDE` 默认 `feat-review-flow`（heavy 改单独定时），报告顶部注明"heavy 未纳入本轮"。
- P2-3：`GERRIT_HTTP_PASSWORD` 去掉 `change-me` 弱默认，compose 用 `${GERRIT_HTTP_PASSWORD:?}` fail-fast，.env 显式配置（与 LDAP 侧一致）；JCasC 用 `${GERRIT_HTTP_PASSWORD}` 无默认。

### 验收
- 门禁：`make check` / `check-all` / `test` 全绿（含 Dockerfile 引用断言、自检整字段匹配）；check-dockerfiles/check-selfcheck 正反双向验证通过。
- 反证：quota-guard 正常 PASS(exit0)/容器不存在 BLOCKED(exit3)/`--cpus 2` BLOCKED(exit2 NanoCpus=2000000000)/证据过期+缺失 Quota gate BLOCKED；`full-quota PASS` 仅 PASS 态出现。
- 终验：容器重建（jenkins/agent 新挂载）+ JCasC reload（22 Job）+ verify-quota-guard 正反（SUCCESS/篡改 FAILURE）+ selfcheck #10 PASS 19/19（报告快照全修复：commit=f0084b2/version=2.580.2/images 键值/heavyNote）；报告 URL 200 no-store、敏感扫描空、12/12 healthy、Gerrit open=0。详见执行日志。

## [m2.4-selfcheck] — 2026-11-26（M2 增补：收口小项 + 每服务 Dockerfile + Gerrit 手册 + 自检框架）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `c0b58c3`（tag `m2.3-closeout`）。依据《OrgFlow M2.4 施工文档》。详见 `docs/records/执行日志/2026-11-26.md`。

### Phase0（7 条小项）
- verify-service.groovy 注释 8→12 + 12 条单服务 Job 加 `cron('H 2 * * *')`；reload JCasC 实证 `<spec>H 2 * * *</spec>`。
- builder compose 加 `--oci-worker-gc-keepstorage=20480`（文档写"20GB"，该参数单位为 MB，20480=20×1024；直接写 `20GB` 会让 buildkitd 启动失败/容器 UNHEALTHY，已修正）。
- manifest builder 行历史 10 列错位修正为 9 列，`public_path` /none→/status，首页 builder 卡指向 /status。
- Gerrit SSH 固定校验：`ssh-keyscan -p 29418 gerrit` 落 `config/jenkins/known_hosts` 挂到 agent（`ro`），Jenkinsfile 两处去 `StrictHostKeyChecking=no` 改 `UserKnownHostsFile=... + StrictHostKeyChecking=yes`。
- jenkins/agent/builder/registry 经 `up.sh --recreate --no-pull` 重建（沿用 M2.3 GHCR 不可达限制）。

### Phase1（每服务 Dockerfile + 门禁）
- 新增 `services/gerrit/Dockerfile`（官方镜像 @sha256 + OCI LABEL，不覆盖 entrypoint）、`services/certs-init/Dockerfile`（ubuntu:24.04@sha256 + openssl）。
- 新增 `scripts/check-dockerfiles.sh`（存在性/FROM@sha256/source LABEL/UPSTREAM 一致）接入 `make check`；11 个现有 Dockerfile 补 source LABEL。
- 同步 5 个 HASHED 服务内容哈希到 lock/images.env/compose（等价 tag）；供应链文档登记 gerrit 上游 digest。

### Phase2（Gerrit 人工手册）
- 新增 `docs/使用手册/Gerrit-人工使用指南.md`（LDAP 登录/SSH key/clone/hook/push/网页评审/cgit/故障）；README 索引 + 按角色阅读；状态页 gerrit 行链到 URL_GERRIT(:8443，域名走配置项)。

### Phase3（自检框架 + HTML 报告）
- 清单真源 `ci/selfcheck/checks.tsv`（19 项：13 服务 + lan-all + 6 功能级）；`scripts/check-selfcheck.sh` 双向门禁接入 make check。
- `selfcheck` 编排 Job（agent none，build 子 Job，SKIPPED/PASS/FAIL/PARTIAL 语义）+ 自包含 HTML/JSON 报告（内联 CSS、无外链、环境快照/明细/失败展开/未覆盖提示）。
- 共享卷 selfcheck-reports（Jenkins rw / Caddy ro）+ Caddy `handle_path /reports/*`（no-store）；首页/状态页加自检报告链接。
- 6 条功能级 Job：public-urls/cgit-smart-http/registry-auth/jenkins-theme/status-page/gerrit-review-flow（heavy）。
- 文档：`docs/运维/自检框架.md` + 新增服务 SOP 补 Dockerfile/checks.tsv 硬要求；新增 `gerrit-http` Jenkins 凭据（env 注入）。

### Phase3 终验（build #8）
- 全量 selfcheck 19/19 SUCCESS（含重项 feat-review-flow 19s），总判 PASS FAIL=0 SKIP=0；报告 latest.html/json + selfcheck-8.html/json，Caddy 三 URL 全 200 + `Cache-Control: no-store`，敏感词扫描为空。
- 12/12 容器 healthy，`/status` 14 行（13 服务 + 表头）；Gerrit open change 归零；make check / check-all / test 全绿。

### Phase3 验收修复（端到端实测发现）
- **controller executor**：JCasC 原 `numExecutors: 0` 使 selfcheck 的 `node('built-in')` 永远停在 "Waiting for executor"；改为 `numExecutors: 1`（仅 selfcheck 用，不碰凭据/无 docker.sock）。子 Job 仍在 orgflow-agent。
- **脚本沙箱**：Pipeline 用 `groovy.json.JsonOutput/JsonSlurper` 被 script-security 拒绝；改为脚本级变量传数据 + 手工 JSON/HTML 字符串拼接，无 groovy.json。
- **结果口径归一**：子 Job 返回 `FAILURE`，报告计数只认 `FAIL` 导致总判假绿；记录时统一 `FAILURE→FAIL`。
- **报告卷属主**：`docker volume create` 默认 root:root 755，jenkins(uid1000) 写 `writeFile` 抛 AccessDeniedException；`up.sh` 卷预建后用 Jenkins 镜像以 root `chown 1000:1000`（幂等）。
- **Caddy 报告挂载**：卷挂 `/srv/reports` 使 `latest.html` 落在卷根，但 URL `/reports/selfcheck/latest.html` 映射到 `/srv/reports/selfcheck/latest.html` → 404；改挂 `/srv/reports/selfcheck`，URL 全 200 + `Cache-Control: no-store`。
- **verify-feature.sh**：新增脚本缺可执行位（exit 126）；status-page 用未定义 `$msvc`（dash `set -u`）；urls 的 registry 公网 Funnel 链路在容器内不稳（000），改判内网 `registry:5000/v2/` 匿名 401（鉴权由 feat-registry-auth 全覆盖）。
- **Gerrit 评审流探针**：canonicalWebUrl 指向公网 8443，容器内照直连会 301→GnuTLS 失败；HTTP 交互注入 `Host: <canonical>` + `X-Forwarded-Proto: https` 绕开重定向，push/clone/hook/REST 全走内网 :8080；commit 必须用已注册邮箱（ci-bot 无注册邮箱会被拒）。Verified 查询与 abandon 封装为共享库脚本 `gerrit-check-verified.sh` / `gerrit-abandon.sh`（避免 Groovy 三引号对 `$` 与 JSON 引号的转义坑）；凭据跨 stage 不继承，Wait 阶段单独 withCredentials；dash 禁 `[[ ]]`。终验：change #46 → build-from-gerrit #12 SUCCESS → Verified+1（第 2 次查询命中）→ post.always abandon HTTP 200 → open 列表归零。M2.3 遗留 #24/#25 + 探针 #41~#45 全部清理。
- **环境恢复**：会话中 Docker daemon 被重置到空 data-root，靠 `/etc/docker/daemon.json` 的 `data-root=/ags/workbuddy-data/docker-main` 重启 daemon 找回 69 镜像/10 卷/全容器，按依赖顺序 start 恢复 12/12 healthy。

## [m2.3-closeout] — 2026-11-26（收口复核：判据 C 闭环 + P2 收口）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `730cdec`（tag `m2.3-gerrit-ci`）。依据《orgflow-M2.3-收口复核-2026-11-26.md》。详见 `docs/records/执行日志/2026-11-26.md`。

### Fixed
- **判据 C 根因（P1）**：buildkitd 拉 `docker.io/library/ubuntu:24.04@sha256:...` 直连 `registry-1.docker.io` 超时。两处修复：① `services/builder/buildkitd.toml` 给 docker.io 配内容寻址镜像站 `docker.m.daocloud.io`（digest 引用同样可解析，不改任何 Dockerfile/@sha256）；② `services/builder/compose.yml` 给 buildkitd 显式加 `--config=/etc/buildkit/buildkitd.toml`——rootlesskit 重执行时未读默认路径，是 mirror 配置一直没生效的真正根因。
- **P2-3 IP 硬编码**：Pipeline `REGISTRY` 从 `192.168.90.20:5000` 改为 DNS 服务名 `registry:5000`；buildkitd.toml 同步声明 `registry:5000 http=true`。
- **P2-4 CI 最小权限**：registry entrypoint 支持第二个 htpasswd 用户，CI 用独立账号 `ci-push`（.env 注入），不再复用 admin；admin 保留供运维。
- **P2-5 serverId 去硬编码**：gerrit entrypoint 不再写死 UUID 常量，单一真源改为 etc 卷内 `server_id` 文件（迁移时从 gerrit.config 读存量 id，避免存量 change 不可写）。
- **P2-2 状态页文案**：router STATUS_META 补 builder 条目（探测 `buildctl debug workers`、入口 `tcp://builder:1234`（仅内网））。
- **P2-7 文档漂移**：jenkins.md / jenkins.yaml 注释 Job 数 9→14、DSL 3→4。
- **Pipeline 回写语法（端到端踩坑）**：Gerrit 3.9 `gerrit review` 第二参数必须是 patchset 序号而非 revision hash，也不能省略——改 `gerrit review ${GERRIT_CHANGE_NUMBER},${GERRIT_PATCHSET_NUMBER} --verified +1`（GERRIT_PATCHSET_NUMBER 由 gerrit-trigger 注入，缺失回退 1）；子串 `${VAR:0:8}` 在 dash 下 Bad substitution，改 `cut -c1-8`。
- **Verified 被 gerrit-trigger 覆盖（关键）**：server 级三项 Verified=0 时插件成功仍以自身账号回写 `autogenerated:jenkins-gerrit-trigger` 的 Verified=0，且时序晚于 Pipeline SSH +1，把自动 +1 覆盖回 0。修法：Job DSL `skipVote { onSuccessful(true) onFailed(true) onUnstable(true) onNotBuilt(true) onAborted(true) }`，插件对所有结果不投票，Verified 完全由 Pipeline 独占。

### Verified
- **判据 C 端到端 ✅（完整闭环）**：推 change #25 patchset 4 → gerrit-trigger 自动触发 build-from-gerrit #6 → buildkit 拉带 digest 的 ubuntu base（走 daocloud）→ build+push `registry:5000` → REST 校验 → SSH `gerrit review 25,4 --verified +1` → 构建 `SUCCESS`；`gerrit query --all-approvals` 显示仅 PS4 带 `Verified=1`（PS1/2/3 空），skipVote 后不再被插件覆盖。**失败不回写反证仍成立**（前几轮 build #3/#4/#5 失败时 post.failure 只 echo、approvals 空）。
- P2-6 清理：abandon change #1/#21/#22/#23，仅留 #24（反证样本）与 #25（e2e 成功样本）。
- P2-1 巡检：`verify-builder #1 SUCCESS` + `verify-lan-all #16 SUCCESS`（builder 上线后首次覆盖 13 服务）。
- registry 双用户鉴权：`ci-push` 200、admin 200、旧口令 `admin:change-me` 401。

## [m2.3-gerrit-ci] — 2026-11-26（Gerrit → Jenkins 触发链）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `8caf5bd`。依据《orgflow-M2.3-触发链施工文档-2026-11-26.md》。详见 `docs/records/执行日志/2026-11-26.md`。

### Added
- **rootless BuildKit builder（M2.3.1）**：独立 `of-builder` 容器，`BUILDKIT_HOST=tcp://builder:1234` 供 agent 提交构建；registry 明文 HTTP 口径（`buildkitd.toml` 声明 `192.168.90.20:5000 http=true`），不改 registry 为 HTTPS（否则 Funnel 回源 502）。镜像 `m2-builder:ctx-9e393f1c9787`，USER 1000（数字 UID）修上游 rootless 镜像无 buildkit 用户名问题。
- **agent buildctl（M2.3.1）**：jenkins-agent 镜像多阶段 COPY buildctl v0.16.0，`ctx-951abc7a53fd`。
- **gerrit-trigger JCasC server（M2.3.2）**：`unclassified.gerrit-trigger.servers[].config` 配 host=gerrit/29418、user=ci-bot、credentialsId=gerrit-ci-ssh、Verified 成功+1/失败-1/开始0；前端 URL 走 `GERRIT_FRONTEND_URL` env（由 PUBLIC_HOST/FUNNEL_PORT_GERRIT 派生，不硬编码）。
- **build-from-gerrit Job/Pipeline（M2.3.3）**：Gerrit patchset-created（项目 orgflow-devops / 分支 main）触发 → checkout GERRIT_REFSPEC → buildkit build+push registry → REST 校验 manifest → SSH review 回写 Verified +1；失败不回写。

### Fixed
- **jenkins crash loop 根因1**：JCasC 符号名须 `gerrit-trigger`（连字符），写 `gerritTrigger` 报 UnknownAttributesException + BootFailure。
- **jenkins crash loop 根因2**：gerrit-trigger 3.x Job DSL 用 `triggerOnEvents{}` + `gerritProjects{gerritProject{ compareType/pattern/disableStrictForbiddenFileVerification/branches }}`；空 `<gerritProjects/>` 导致 Job 不响应任何事件（判据 B 首轮 0 构建的根因）。
- **Pipeline python3 依赖**：agent 无 python3，改用纯 shell base64 生成 registry docker config.json。
- **CI locale 口径**：build-images.yml ctag step 加 `LC_ALL=en_US.UTF-8`，消除 image-hash sort 顺序漂移导致 tag 不一致。

### Verified
- 判据 A ✅：插件 active、JCasC export 含 gerrit-trigger、凭据加载、server `Ready to receive data from Gerrit`。
- 判据 B ✅：推 patchset 后 40 秒内 build-from-gerrit #1 自动触发。
- 判据 C（手工）✅：`gerrit review --verified +1` 回写 change #1 `Verified=1 by ci-bot`。自动端到端当时因 docker.io 出网阻塞；**已于 m2.3-closeout 段闭环**（见本节上方：docker.io 镜像站 + buildkitd 显式 config，change #25 patchset 4 自动 +1）。
- 反证 ✅（验收 11）：server 级 Verified 全部设 0（插件不碰），+1 只由 Pipeline 成功末段 SSH 独占回写；`post.failure` 只 echo。推 change #24 → build #2 失败 → Change Verified 保持不变（approvals 为空），失败不假绿实证。
- builder/agent 内网三条链路（builder:1234 / gerrit:29418 / registry:5000）全通；全栈 13 服务 healthy。

### 边界
- 自动 Verified 端到端曾受 docker.io 出网阻塞（非配置问题），**m2.3-closeout 已补镜像站闭环**。Harbor 官方栈、registry 内网 HTTPS 仍按既定路线不做。

## [m2.2-registry-p0] — 2026-11-26（第六轮 P0：公网强口令 + 清测试仓）

> 分支 `feat/m2-gerrit-cgit-harbor`，基线 `b92f285`。依据《orgflow-M2.2-第六轮收口复核-2026-11-26.md》，本轮只补 P0 安全项、不开 M2.3。详见 `docs/records/执行日志/2026-11-26.md`。

### Fixed（P0 安全）
- **公网 registry 默认口令** → 强口令：`:10000` 曾以骨架默认 `admin/change-me` 暴露公网且残留测试仓 `demo`。改为 gitignore `.env` 注入强口令，`ENV_FILE=.env bash up.sh --recreate registry --no-pull` 重建，entrypoint 幂等重渲染 htpasswd。验证：新口令 `/v2/_catalog` 200、旧口令 401、匿名 401。
- **测试仓 `demo` 清除**：删卷内 `repositories/demo`（含失败 push 残留），`_catalog` 现返回 `[]`。
- **安全文档入库**：registry.md §4/§6.1/§7、安全基线.md §1/§3/§4 写明公网强口令基线、校验命令与测试仓清理要求；口令不入库/不进日志。

### 边界
- 不开 M2.3（触发链/单服务 Job cron/registry GC/内网 HTTPS 均未开始）。

## [m2.2-registry] — 2026-11-26（M2.2 registry 上线 + 第五轮收口）

> 分支 `feat/m2-gerrit-cgit-harbor`，tag `m2.2-registry`。基线 `e3d3331`。详见 `docs/records/执行日志/2026-11-26.md`。本版只做 M2.2 收口，不开 M2.3。

### Added
- **registry:2 轻量镜像仓库（路线 B）**：htpasswd 基础鉴权，`Funnel :10000 → 127.0.0.1:${PUB_HTTP_HARBOR} → 容器 5000`；push/pull 端到端 5/5 验证（401 鉴权、login、push/pull digest 一致、匿名拒绝、门禁全绿）。镜像由 CI 中转推 GHCR m2-registry，国内经南大代理拉取。
- **内网 TLS/insecure 客户端接入清单入库**（registry.md §6.1）：厘清 loopback 内置明文信任 vs 非回环地址需 TLS/insecure，明确 M2.3 两条路线与注入责任人，杜绝配置只活在机器上。

### Fixed（第五回复核 4 P1 + 4 P2）
- P1-1 `/status` 启动快照停在 11 服务 → router 改按 manifest mtime 缓存重建，recreate 后 12 服务含 registry（公网+本地实测）。
- P1-2 `verify-registry` Job 缺失 → JCasC reload（容器内带 crumb，HTTP 302）后 Job 11→12，手动触发 #1 SUCCESS。
- P1-3 镜像命名 m1/m2 混用 → cgit/registry 统一 `m2-` 前缀，四处真源同步（images.env/lock/compose/CI），hash 后缀不变。
- P1-4 registry 无 TLS/insecure 不在仓库 → 见上 §6.1 客户端接入清单入库。
- P2-1 `IMAGE_GERRIT` 墙外 Docker Hub 地址 → 改 GHCR `m2-gerrit:3.9.0`，删过期 TODO。
- P2-2 registry Dockerfile FROM 全零占位 → 改 `ARG BASE_DIGEST=<真实默认值>` + CI `--build-arg` 注入，仓库可直接构建；门禁 check_base 同步放宽。
- P2-3 首页 registry 卡片文案含糊 → 明确「API only · 公网 :10000 / 内网 :18086（无 Web UI）」。
- P2-4 `verify-lan-all` 未含 registry 全量跑 → #15 SUCCESS（11 项含 registry）。

### Verified
- `make check`/`check-all`/`test` 全绿；verify-registry #1、verify-lan-all #15 SUCCESS；公网 `/`、`/healthz`、`/cgit/`、`/status`=200，`:10000/v2/`=401。

### 边界
- Harbor 官方栈（UI/项目/robot）按 B 路线有意不做；M2.3 Jenkins 触发链、内网 registry TLS 落地未开始。

## [m2.1-v1.0] — 2026-11-26（M2.1 封版：Gerrit + cgit 上线，评审流 4/4 通过）

> 分支 `feat/m2-gerrit-cgit-harbor`，封版 tag `m2.1-v1.0` @ `fca5c19`。详见 `docs/records/执行日志/2026-11-26.md`。交付主线仍是 `feat/m0-release` / `feat/m1-jenkins` 的历史链，本 tag 标记 M2.1 功能面封版快照。

### Added
- **Gerrit 3.9 代码评审服务**：LDAP/osixia 统一身份接入（正确键 `username/password/supportAnonymous=false`），`accounts.visibility=NONE` 收紧账号枚举；业务仓 `orgflow-devops` 导入源码 188 文件为 commit `cba7f0b`；Web `:8443`、SSH `:29418`（Funnel 不转 TCP，tailnet/本机可达）。
- **cgit 1.2.3 浏览服务**：`/cgit/` 公网只读视图，`repo.` 显式白名单（排除 All-Projects/All-Users），`git-http-backend` 支持 smart-http clone；镜像 tag `ctx-e0643a8c475e`（内容哈希，GHCR + 南大代理中转）。
- **状态页/主页/门禁同步**：router `/status` 从 manifest 动态生成（9→11 服务含 gerrit/cgit）；主页补 Gerrit 公网入口；bats 新增 `S_gerrit.bats`/`S_cgit.bats`，verify-lan-all 判据接受安全 3xx。

### Verified
- **评审流 4/4 判据全绿**：HTTP 认证（ls-remote 非 401）、`refs/for/main` 接受（输出 `+/<id>`）、Change #1 浏览器/REST 可见、SSH `gerrit ls-projects` 列出业务仓。截图 `artifacts/m2.1/gerrit-review-open.png`。
- 全量门禁 `make check`/`check-all`/`test` 全绿；Jenkins verify-lan-all #14 SUCCESS 失败 0 项；公网 443/8443/`/status`=200。

### 边界
- Harbor/M2.2 未纳入本版：无容器/无配置，10000→18086 无后端；按施工文档 A/B 路线对比另起阶段。

## [m2.0-prep] — 2026-11-25（M2.0 前置治理 P1~P4，未封版）

> 分支 `feat/m1-jenkins`，基线 `m1-v1.0 @ 72c2f63`。详见 `docs/records/执行日志/2026-11-25-r8.md`。M2.1+ 服务部署待资源闸门决策（内存 5.62GiB < 8GiB）。

### Fixed
- **up.sh 假成功（M1 r7 遗留真正根因）**：`DC()` 未透传 `"$@"` 导致 compose 子命令被丢弃却退出 0；修复透传 + pull/up 捕获退出码打 stderr 末 15 行 + FORCE 分支 StartedAt 比对。坏镜像实测 exit 1 并打印错误，正常重建 StartedAt 变化。

### Added
- **端口三层模型（M2 §1）**：defaults.env 增 9 个端口变量（Funnel 443/8443/10000、回环 18085/18086、容器内 8080/29418/80/8080）；新增 `render-urls.sh` 生成 out/urls.env（公网 URL 单一真源）、`check-ports.sh` 六条门禁（非法 Funnel 口拦截、无字面端口硬编码）；make render / check-fast 接入。
- **资源盘点闸门**：`preflight.sh` 输出 nproc/内存/磁盘三项，全过 exit 0、任一不过 exit 3 建议降级 registry:2（不自动降级、等人定）。
- **服务脚手架**：`services/_template/` 三件套 + `new-service.sh`（生成骨架并打印手工 5 步）；镜像/静态门禁排除 `_template` 模板目录。

## [m1-v1.0] — 2026-11-25（M1 封版：终验 16/16 通过）

> 分支 `feat/m1-jenkins`，基线 `m1-v0.3` @ `df94483`。详见 `docs/records/执行日志/2026-11-25-r6.md`。
>
> 收口（r7）：`jenkins-devtest` 落入 `51-jenkins.ldif` 真源（卷清空可重建）+ `m1-v1.0` 移到收口终态提交 + 重建 router 使 render 模板与运行态一致（详见 `docs/records/执行日志/2026-11-25-r7.md`）。

### Fixed
- **状态页判据 7/8 假绿（终验发现）**：`services/router/server.py` 的 `GET /status` 补齐 `Status-Source: router` 头、HEAD 支持（`curl -sI` 200）与访问日志；表格增「容器」列列全 9 个 `of-*`（含 Jenkins/Agent），`grep -c 'of-'` = 9。此前 `/status` 实测 501/无头/无容器名，与 A 部分「已切 router」声称不符。server.py 为 bind mount，重建 router 容器即生效，镜像未变。

### Verified
- 全量拆除（保留 4 卷 + 1 网络，CA sha256 未变）后按 manifest 重建，16 条终验判据全部通过：容器/IP/DNS/入口/Jenkins 冷启/主题/agent/匿名/9 Job 全绿/定时/幂等/门禁。

## [m1-v0.3] — 2026-11-25（r5：门禁真转绿 + 镜像内容哈希 + 冗余清理）

> 分支 `feat/m1-jenkins`，基线 `m1-v0.2` @ `baa0e87`。不合并 main。详见 `docs/records/执行日志/2026-11-25-r5.md`。

### Fixed
- **门禁真转绿（P1）**：`tests/v2.env` 入库（`.gitignore` 白名单），修掉「沙箱假绿、干净克隆红」；r3 日志与 CHANGELOG 的假绿记录改真。`make check` 现 10 项全 ok。
- **upstreamDigest 口径统一（P5）**：dnsmasq/router/certs-init 由自建产物 manifest digest 改为 Dockerfile `FROM` 基底 digest，与其余行同义。

### Changed
- **镜像改内容哈希标识（P2）**：新增 `scripts/image-hash.sh`；M1 jenkins/agent 的 tag 改 `ctx-<12>`、imageId 改 `-`、contextSha256 为主标识；两个 compose 与 `images.env` 同步；`check-images.sh` 重写（扫描派生 + HASHED 强校验 + 删 source/PENDING）；CI 删 fill-pending 回填链路；删除 `build-images.sh`/`update-images-lock.sh`；Makefile `images-lock`→`images-hash`。反向门禁生效（改 Dockerfile 不更 lock → `make check` 红）。
- **摘除失败通知死代码（P3）**：无邮件/webhook 通道，删 `notify-feishu.sh` 与 Jenkinsfile `failure` 块，E2 暂缓。
- **状态页去重（P4）**：Caddy/router 内联 HTML 改为 `reverse_proxy router:8080`，router `GET /status` 为唯一真源（静态生效，运行时下次部署 reload）。
- **服务清单一致性门禁（P4）**：新增 `scripts/check-service-list.sh` 挂进 `make check`；`verify-service.groovy` 7→8 修漂移。
- **文档口径统一（P5）**：「7 服务/6 常驻」→「9 服务（8 常驻 + certs-init）」；jenkins.md scriptPath/镜像口径改正；镜像与供应链.md §3/§4 重写。

## [m1-v0.2] — 2026-11-25（M1 收口：主题生效 + 定时巡检 + 失败通知）

> 分支 `feat/m1-jenkins`，tag `m1-v0.2` @ `9e20dd4` 之后的本轮 commit。`m1-v0.1` 保留作历史（指向旧链，孤儿 tag），基线以本版为准。

### Fixed
- **深色主题真正生效（判据1，原 T7 高危）**：GHCR 新镜像 `sha-9e20dd4`（`sha256:459b0d97…43dfa`）含 `theme-manager`/`dark-theme` 插件；回填 `services/jenkins/compose.yml` digest 与 `tests/images.lock` imageId（`8ca8cb67…`），用新镜像重建 jenkins。公网 `/jenkins/appearance/` 显示 Dark、`disableUserThemes`，pluginManager 含两插件，UI 深色生效且用户不可改。
- **配置/镜像一致（判据2）**：compose digest == 线上 RepoDigest == lock imageId；`check-images --mode=lock` 零 PENDING。

### Added
- **E1 定时巡检**：`verify-lan-all.groovy` 加 `triggers { cron('H 2 * * *') }`（每日 02xx 随机分钟，保留手动触发）。
- **E2 失败通知**：新增 `ci/shared-library/bin/notify-feishu.sh` + Jenkinsfile `post.failure` 用 `withCredentials` 绑定 `feishu-webhook`（webhook 走 plain-credentials，不入库）；缺凭据优雅跳过，配置后失败即发。

### Notes
- Jenkins 重建必须走 `up.sh`（注入 agent 密钥），裸 `docker compose up` 会触发 JCasC `failed-boot-attempts` 崩溃循环——详见 `docs/records/执行日志/2026-11-25-r3.md`。
- 验收：9/9 Job 全绿、公网端点无回归。`make check` **当时未真绿**（§8 `tests/v2.env` 未入库，干净克隆红；沙箱因遗留文件假绿），已于 r5 §1 修复。E2 webhook 实测待用户提供飞书 webhook 凭据；E1 自动构建次日观察。

## [m1-v0.1] — 待发布（M1：Jenkins + Agent + 局域网检测）

> 分支 `feat/m1-jenkins`，从 `feat/m0-release` @ `0e5562c`（tag `m0-v1.1`）拉出；`main` 不动。

### Added
- **Jenkins controller**（M1-T1/T3/T5）：JCasC 唯一配置真源 `config/jenkins/jenkins.yaml`（LDAP 登录 + projectMatrix 授权 + SSH 节点 + 凭据 + 9 条 Job）；钉死插件版本（`services/jenkins/plugins.txt` name:version + `plugins.lock.md`）；官方 update center 源。
- **Jenkins SSH agent**（M1-T2）：`services/jenkins-agent`（无 docker.sock、普通用户 jenkins、固定 host key、探测工具链）+ `scripts/gen-jenkins-secrets.sh` 幂等生成 secrets/。
- **Job as Code + 挂载共享库**（M1-T5）：9 条 Job 由 `config/jenkins/jobs/*.groovy` 生成，流水线逻辑在 `ci/jenkins/pipelines/`，探测脚本 `ci/shared-library/bin/check-lan.sh` 挂载即生效。
- **LDAP 账号/组**（M1-T3）：`jenkins-ci`（口令 `Jenkins@2026`）、`jenkins-admins`（全权）、`jenkins-dev`（只读+构建）。
- **HomePage 卡片**（M1-T6）：服务状态 6→8（+Jenkins、Jenkins Agent），公网入口 4→5（+/jenkins/）。
- **文档**（M1-T7）：`docs/services/jenkins{,-agent}.md`、架构/启动顺序/镜像与供应链/安全基线同步，docs 登记册 +2。

### Changed
- **公网入口**（M1-T4）：`config/routes.yaml` 加 `/jenkins` `strip:false`，router `render()` 输出 `handle /jenkins/*`（保留前缀）而非 `handle_path`（剥前缀致 404）；Caddyfile 与 router PUBLIC_FIXED/STATUS_HTML 同步（7→9 服务）。
- **门禁/CI**（M1-T0.5）：`check-images.sh` SERVICES/BUILDABLE 加 jenkins 两项、pull_policy 放宽 `never|missing`；`build-images.yml` matrix 加两个镜像、分支触发 `feat/m1-jenkins`、fill-pending ref/base 动态化并把 CI digest 回填两个 compose；仓库变量 `PUSH_IMAGES=true`。
- **GitHub 清理**（M1-T0）：25 条历史 open issue 关单（#147 打 icebox）、5 个里程碑删除。

### Fixed（2026-11-25 二轮实测修复，T1~T9）
- **compose YAML**（T1）：`services/jenkins/compose.yml` 的 `environment` map/list 混用改统一 mapping，密钥两项改 `${VAR:-}`；补 `TZ`。
- **Job 全红根因**（T2/T3）：`check-lan.sh` 顶部 `DOMAIN:?` 断言改 `need_domain()` 按需解析（curl 探针不依赖 DOMAIN），case 认 `dns|dnsmasq`；agent compose 只读挂 `config/defaults.env` 兜底；`jenkins-agent` 分支加 uid/java/dig/DNS 真断言并纳入全服务检测（8 项）。
- **LDAP 固化**（T4）：账号/组从 `50-users.ldif` 拆到 `config/ldap/51-jenkins.ldif`（空卷首启按序导入）；`jenkins-admins` 含 jenkins-ci + zeek.zhao 两 member；给出已有卷 ldapadd 补齐命令（文档）。
- **匿名 403 白屏**（T5）：`jenkins.yaml` 加 `Hudson.Read:anonymous`（只 Overall/Read，不泄漏 Job），消除白底 "Authentication required"。
- **scheme 泄漏**（T6）：Caddyfile 与 router render 两处 `header_up X-Forwarded-Proto https`/`X-Forwarded-Host`，外链 `report-uri` 由 http 变 https。
- **深色主题**（T7）：`plugins.txt` + `plugins.lock.md` 钉 theme-manager/dark-theme（update-center 实解析），`jenkins.yaml` 顶层 `appearance.themeManager`（待镜像重建后生效）。
- **Job 冒烟**（T8）：新增 `scripts/jenkins-smoke.sh` + `make smoke` + `tests/bats/10_jenkins_smoke.bats`；反代 crumb 403 时用 `JENKINS_CONTAINER` 走容器内通道；日志落 `artifacts/jenkins-smoke/`（gitignore）。
- **收口**（T9）：`up.sh` 自动从 secrets 注入 SSH 密钥；`images.lock` 回填 jenkins 两行真实 imageId（零 PENDING）；`manifest.tsv` health_url 改容器内地址并标注为文档字段；`test-static.sh` 加 YAML 解析校验 + JENKINS_URL/PUBLIC_HOST 一致性断言；`JENKINS_URL` 由 PUBLIC_HOST 派生去重。

## [m0-v1.1] — 2026-11-24（已打 tag）

> 分支 `feat/m0-release`，tag `m0-v1.1` @ `abf5034`。本轮为展示层优化与清理，不动 `main`、不重建网络/数据卷。

### Added
- `CHANGELOG.md`、`docs/运维/备份与恢复.md`、`docs/运维/升级与回滚.md`、`docs/运维/安全基线.md`（R8 文档补漏）。

### Changed
- **R6 HomePage 展示层重构**（Closes #241，PR #242）：
  - 分组改名：`局域网服务状态` → `服务状态`、`域名入口` → `公网入口`，`settings.yaml` layout 键同步。
  - 服务状态组 6 张全保留；公网入口组改为 4 张，按 `public_path` 非 `/status`/非 `/none` 规则筛选真实入口，删除 DNS/LDAP/Caddy 三张「点进去还是 /status」的假入口卡，固定追加「状态总览 → /status」。
  - 移除 `[lan][domain][LAN][DOMAIN][NO-UI]` 方括号前缀；description 统一为「一句中文用途 · 协议/端口」；名称去冗余后缀（统一面板→统一入口、LDAP 管理页→LDAP 管理、路由状态→路由服务）。
  - `custom.css` 分组标题与卡片间距微调；bats 断言同步为 6+4 卡与新组名。
- **R7 分支清理**：远端 14 条分支收敛到 2 条（`main`、`feat/m0-release`）；4 条未并入的历史尝试分支归档为 `archive/*` tag 后删除。

## [m0-v1.0] — 2026-11-24

> 交付主线 `feat/m0-release` @ `3d318c0`，tag `m0-v1.0`。`main` 保持只读历史参考。

### Added
- 从零构建的 7 服务最小 DevOps 底座：DNS（dnsmasq）→ 证书（certs-init）→ 网关（Caddy）→ 目录（OpenLDAP）→ 面板（HomePage）→ 管理页（ldapadmin）→ 路由（router）。
- **单域名路径型入口**：HomePage 占根 `/`，`/ldapadmin/`、`/router/`、`/status` 走路径前缀；Tailscale Funnel 在边缘终止 TLS 后回源 Caddy `:PUBLIC_PORT`，无子域 vhost。
- 逐服务 compose（`services/<svc>/compose.yml`）、`up.sh` 按 `services/manifest.tsv` 顺序启动、配置即代码（域名/端口用 `.env` 占位符）。

### Changed
- **R1 公网信息泄漏收口**（Closes #238）：`/api/services`、`/api/widgets` 对公网返回 403（Host 判定）；`POST /router/render` 403；`/router/` 308。线上实测公网不再泄漏内网 IP/宿主指标。
- **R2 文档与事实对齐**（Closes #239）：启动顺序、分支口径、变更台账、LDAP 口令等五处。
- **R3 HomePage 卡片标签**（Closes #240）：manifest 增加 `tags` 列（当时降级为 description 前缀；R6 起不再参与展示）。
- **R4 流程收口**：分支策略改为 release 体系，关闭遗留 PR #207。

### Security / Ops
- **镜像双模式**：默认走 GHCR `@sha256` digest（`USE_LOCAL_IMAGES=0`，零停机）；本地自建（`USE_LOCAL_IMAGES=1`）为可选模式，须 lock 无 PENDING 且本地镜像存在，否则告警回退 GHCR。
- **公网暴露面**：仅 Tailscale Funnel 一个入口；Caddy admin `:2019` 只绑内网，LDAP `389` 不出网。
