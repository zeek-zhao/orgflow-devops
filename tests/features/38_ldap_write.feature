# Feature: LDAP 写路径
  行为真源：与 tests/bats/38_ldap_write.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。
Feature: LDAP 写路径
  @REQ-M0-A1
  Scenario: ldap: 写路径——建号(uidNumber+SSHA)→绑定成功→错口令拒绝→删除后绑定失败
    Given 目录管理员凭据在容器环境变量里且探测用户名不与现有用户冲突
    When 建号(含 uidNumber 与 SSHA 口令哈希)后分别用正确口令、错误口令绑定，再删除后重绑
    Then 正确口令绑定成功，错误口令与删除后绑定都必须收到 INVALID_CREDENTIALS
  @REQ-M0-A3
  Scenario: ldap: 写路径——组授权可运营:docs-users memberUid 增删即时生效
    Given 授权组 docs-users 是网关组授权的真源
    When 对探测账号执行 memberUid 增删
    Then 组搜索结果即时反映增删，删除后组内不再有该账号
