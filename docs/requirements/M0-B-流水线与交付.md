# M0-B · 流水线与交付（REQ-M0-B*）

> 需求基线 · DOC-R-006 ｜ 状态：approved ｜ 负责人：zeek.zhao ｜ 评审日期：2026-11-11 ｜ 复审：12 个月
> 本域 10 条，覆盖 Issue #3 #44 #45 #46 #90 #91 #92 #93 #96 #115 #117（10 关闭 / 1 open）。
> 规则见 [需求基线入口](README.md)：**要求与判据冻结，现状与证据可变**；判据前的 ⚠ 表示干净 clone 上复现不出来。

## 1. 需求表

| 编号 | 要求 | 验收判据 | 现状 | 证据 |
|---|---|---|---|---|
| **REQ-M0-B0** | deploy / backup / restore / verify / nexus 五类 Job 可按参数执行；敏感值一律走 `withCredentials`，不落 Job 定义 | `make jobs-test` → 退出码 0；`python3 scripts/test_jobs.py` 绿；`bats tests/bats/31_verify_jobs.bats` 绿 | 已实现 | [#3](https://github.com/zeek-zhao/orgflow-devops/issues/3) · PR #8 #76 #122 |
| **REQ-M0-B1** | Jenkins 镜像自带 pipeline / git / credentials / JCasC 等常用插件，装机即可用，插件清单在仓库内可审 | `grep -c workflow-aggregator services/jenkins/plugins.txt` → `1`；`bats tests/bats/16_jenkins.bats` 绿；反证：从 `plugins.txt` 删掉 `workflow-aggregator` → 镜像自检必须红 | 已实现 | [#44](https://github.com/zeek-zhao/orgflow-devops/issues/44) [#90](https://github.com/zeek-zhao/orgflow-devops/issues/90) · PR #48 |
| **REQ-M0-B2** | 五类 Job 都是 declarative pipeline，同类 Job 内 stage 数 ≥ 2、stage 名不重复、stage 体非空、`options{}` 只允许运行时认的类型 | `python3 scripts/test_job_pipelines.py` → 退出码 0；反证：把两个 stage 改成同名 → 必须红；把 `options { timestamps() }` 塞回去 → 必须红 | 已实现 | [#91](https://github.com/zeek-zhao/orgflow-devops/issues/91) |
| **REQ-M0-B3** | Manage Jenkins 的警告逐条处置：能修的修掉，不能修的在台账里写编号 / 现象 / 处置 / 理由 / 复核日期 | ⚠ 需真机：`bash scripts/collect-jenkins-warnings.sh` 抓到的警告数与台账条目数一致，且每条有「已修」或「不修 + 理由」；反证：人为制造一条反向代理 URL 不匹配的警告 → 核对脚本必须报未登记 | 已实现 | [#92](https://github.com/zeek-zhao/orgflow-devops/issues/92) |
| **REQ-M0-B4** | 一个脚本完成 list / get / run / log 四件事，用 API token 免 crumb，每步打印请求与结果，错误必须非零退出 | `bash scripts/test_jenkins_cli.sh` → 退出码 0（离线自检）；⚠ 四个子命令的真机实测需部署机；反证：故意用错 token → 四条命令必须都非零退出 | 已实现 | [#96](https://github.com/zeek-zhao/orgflow-devops/issues/96) |
| **REQ-M0-B5** | Nexus 备份 Job 同时产出**数据库与 blob store**，可恢复演练；GHCR 推送配置成文、可照抄复跑 | `python3 scripts/test_nexus_archive.py` 绿；反证：只备份 db 不备份 blobs → 内容级门禁必须 rc=1 | 已实现 | [#93](https://github.com/zeek-zhao/orgflow-devops/issues/93) · PR #108 |
| **REQ-M0-B6** | Jenkins 有独立的 docker agent 节点（SSH 接入、挂 docker socket）；`securityRealm` / 凭据 / 全局共享库 / agent cloud **全部由 JCasC 声明**，不写 `init.groovy.d` | `bats tests/bats/23_jenkins_agent.bats` 绿（三条：容器与 docker CLI、JCasC 节点在线且带标签、SSH 私钥进凭据库）；反证：从 `config/jenkins.yaml` 删掉 agent cloud 段 → 「节点在线」用例必须红 | 已实现 | [#45](https://github.com/zeek-zhao/orgflow-devops/issues/45) · PR #50 #51 |
| **REQ-M0-B7** | Nexus 从 compose 彻底删除，改由 Job 创建容器并改掉初始随机密码；重复执行幂等 | `bats tests/bats/17_nexus.bats` 绿；`grep -c "nexus:" docker-compose.yml` → `0`；⚠ 幂等性需真机重跑 | 已实现 | [#46](https://github.com/zeek-zhao/orgflow-devops/issues/46) · PR #52 #70 #71 #108 |
| **REQ-M0-B8** | Jenkins 插件集扩充到可用水平、默认 dark 主题、禁止自动更新插件、CI 镜像链路与已发布镜像一致 | `python3 scripts/test_ci.py` → 退出码 0；`bats tests/bats/16_jenkins.bats` 绿；反证：把 `images.lock` 里某个 digest 改成占位串 → `make images-guard` 必须红 | 已实现 | [#115](https://github.com/zeek-zhao/orgflow-devops/issues/115) |
| **REQ-M0-B9** | Nexus 提供 docker 与 pypi 仓库，并完成**拉、推两个方向**的实测 | ⚠ 判据缺失：M0 关闭时这条仍未开工，没有可执行的验收命令 | 未实现 · 转入 M1 | [#117](https://github.com/zeek-zhao/orgflow-devops/issues/117)（open） |

## 2. 要点与坑

### B1 与 B8 是两条 Issue，一条需求

- #44（M0-02）是首次做自定义镜像：JDK21 + 7 个插件 + 镜像链改由 GitHub 侧构建。
- #90（REQ-M0-B1）是事后补的需求编号，要求同一件事。
- #115 又把插件集扩到可用水平，并加了 dark 主题与禁自动更新。

所以 `REQ-M0-B1` 的证据列同时挂 #44 与 #90，`REQ-M0-B8` 挂 #115。**不是漏了 Issue，是三条 Issue 落在两条需求上**。这是历史分批发需求留下的结构，本轮只做归并，不改编号 —— 改编号会让 `M0-最小核心.md` 与 `docs/services/jenkins.md` 里已引用的 `REQ-M0-B1` 全部失效。

### B2：`options { timestamps() }` 那条教训值得单独记

`timestamper` 插件不在镜像里，所以 `options { timestamps() }` 不是合法 option。它在**运行时**让整条 pipeline 编译失败，而当时的 1–5 条静态判据全部通过 —— 这是「静态检查全绿、运行直接炸」的典型。

第 6 条判据因此改成：`options {}` 里出现的调用名必须在运行时白名单内，白名单**直接抄 Jenkins 报错原文**，不靠自己猜。判据的写法比判据本身重要。

### B5：落地数字（保留，因为它是唯一一次完整取证）

包 870441 B（db 2076672 B + blobs 85 文件 / 830352 B）；drill 卷 db sha256 一致、blobs 数与字节一致、临时容器 20 秒启动后 HTTP 200；反证「只 db」「只 blobs」均 rc=1，「全量」rc=0。

同时修掉一个当时**完全不通**的链路：Nexus 自 #46 移出 compose 后，`backup.sh` / `restore.sh` 里的 `docker compose ps/stop/start nexus` 必然报 `no such service`。修法是在 `scripts/backup-common.sh` 加服务运行时抽象（nexus 走 `docker inspect/stop/start`，容器名可用环境变量覆盖），并在 `backup.sh` 加内容级门禁（缺 db 或 blobs 直接删包报错）。

这条值得留在需求里，是因为它说明 **B7（移出 compose）会静默打断 B5（备份）**，而当时没有一条判据能发现这种跨需求的破坏。

### B3 与 B4 的判据为什么标「需真机」

两条需求的对象都是**运行中的 Jenkins**：警告列表来自 `/administrativeMonitor/`，CLI 四件套要打真实 API。仓里能跑的只有离线部分（警告台账的一致性检查、CLI 脚本的参数解析自检），真正的验收必须在部署机做。

这不影响它们标 `已实现` —— 当时都在真机上取过证。但**干净 clone + `make test` 复现不出来**，所以要标 ⚠，避免有人按 `make test` 全绿就宣称 B3/B4 通过。

### B9：为什么是「转入 M1」而不是「M0 未完成」

M0 已于 2026-11-01 关闭，#117 却仍挂在 M0 里程碑上 —— 这会让里程碑出现「已关闭但还有 open」的矛盾态。处理方式是把 #117（与 #116）移到 M1 里程碑，需求基线里如实写「未实现 · 转入 M1」。

**没有做的事**：没有为了让 M0 看起来完整而把 #117 标成「已降级」。能力缺口真实存在，Nexus 上现在只有 maven2 与 nuget 仓库，没有 docker 也没有 pypi。
