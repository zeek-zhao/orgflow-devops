# Feature: verify-service 任务模板

  行为真源：与 tests/bats/31_verify_jobs.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: verify-service 任务模板
  @REQ-M0-B0
  @REQ-M0-B2
  @REQ-M0-D5

  @REQ-M0-B0
  Scenario: verify jobs: 模板覆盖 10 个 compose 服务 + nexus，与 deploy.sh 口径一致
    Given verify 模板已入库
    When 对照 deploy.sh 服务口径
    Then 模板覆盖 10+1 个服务且口径一致

  @REQ-M0-B0
  @REQ-M0-B2
  Scenario: verify jobs: 模板 DSL 引用 verifyService 且带 DRY_RUN 参数
    Given Job 定义已入库
    When 检查 DSL 引用与参数
    Then 引用 verifyService 且带 DRY_RUN

  @REQ-M0-B0
  Scenario: verifyService: deployable 白名单与 deploy.sh 的 case 完全一致
    Given 共享库与 deploy.sh 就绪
    When 对照 deployable 白名单
    Then 与 deploy.sh case 完全一致

  @REQ-M0-B0
  @REQ-M0-D5
  Scenario: verifyService: backupable 白名单与 backupService/backup.sh 一致（仅真卷服务）
    Given 共享库与 backup.sh 就绪
    When 对照 backupable 白名单
    Then 仅含真卷服务且与 backup.sh 一致
