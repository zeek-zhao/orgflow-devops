# Feature: 备份与恢复

  行为真源：与 tests/bats/30_backup_restore.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: 备份与恢复
  @REQ-M0-D5

  @REQ-M0-D5
  Scenario: backup: ldap 真卷备份产出三件套齐全的归档，--verify 复验通过
    Given ldap 真卷有数据
    When 执行 backup --verify
    Then 归档含 tgz/sha256/meta 三件套且复验通过

  @REQ-M0-D5
  Scenario: restore: --dry-run 只出恢复计划，不停服不碰卷
    Given 已有合法备份归档
    When 执行 restore --dry-run
    Then 只出计划，不停服不碰卷

  @REQ-M0-D5
  Scenario: restore: 注入探测数据后恢复，探测数据消失、基线回到 35 条
    Given 卷内已注入探测数据
    When 执行 restore
    Then 探测数据消失，目录回到 35 条基线
