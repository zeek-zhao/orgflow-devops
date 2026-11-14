# Feature: phpLDAPadmin 管理面

  行为真源：与 tests/bats/11_ldapadmin.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: phpLDAPadmin 管理面
  @REQ-M0-A5

  @REQ-M0-A5
  Scenario: ldapadmin: 管理面站点已摘网关(#86):不再 302 到 oauth2,由 phpLDAPadmin 自身应答
    Given ldapadmin 站点已按 #86 摘除网关
    When 直连站点首页
    Then 不再 302 到 oauth2，由 phpLDAPadmin 自身应答
