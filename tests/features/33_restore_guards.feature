# Feature: 恢复安全护栏

  行为真源：与 tests/bats/33_restore_guards.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: 恢复安全护栏
  @REQ-M0-D5

  @REQ-M0-D5
  Scenario: restore: sha256 清单与归档不一致必须被拒
    Given 篡改归档字节
    When 执行 restore
    Then 清单校验失败必须被拒

  @REQ-M0-D5
  Scenario: restore: meta 服务/卷与恢复目标不匹配必须被拒
    Given meta 记录与目标不一致
    When 执行 restore
    Then 必须被拒

  @REQ-M0-D5
  Scenario: restore: 路径穿越条目必须被拒
    Given 归档含 ../ 路径条目
    When 执行 restore
    Then 路径穿越必须被拒

  @REQ-M0-D5
  Scenario: restore: 逃逸出归档根的符号链接必须被拒
    Given 归档含逃逸符号链接
    When 执行 restore
    Then 必须被拒

  @REQ-M0-D5
  Scenario: restore: 设备节点条目必须被拒
    Given 归档含设备节点
    When 执行 restore
    Then 必须被拒

  @REQ-M0-D5
  Scenario: restore: 目标卷非空且未给 --force 必须被拒
    Given 目标卷非空
    When 不带 --force 执行 restore
    Then 必须被拒
