# Feature: LDAP 目录与账号

  行为真源：与 tests/bats/10_ldap.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: LDAP 目录与账号
  @REQ-M0-A0
  @REQ-M0-A1
  @REQ-M0-A2

  @REQ-M0-A0
  @REQ-M0-A2
  Scenario: ldap: authenticated base, exactly 35 entries, admin mail and three OUs
    Given svc-platform-admin 凭据可用
    When 认证 bind 后统计目录条目
    Then 恰好 35 条，管理员邮件与三个 OU 齐备

  @REQ-M0-A1
  Scenario: ldap: uidNumber 全局唯一（#84 反 regression，曾出现 1009 重复）
    Given 目录已初始化
    When 收集全部 uidNumber
    Then 全局唯一，无 #84 的重复回归

  @REQ-M0-A1
  Scenario: ldap: 恰好 10 个用户条目（posixAccount，#84）
    Given 目录已初始化
    When 统计 posixAccount 条目
    Then 恰好 10 个用户条目
