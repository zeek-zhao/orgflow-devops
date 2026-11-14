# Feature: 认证流——登录之后的真实可用性
  行为真源：与 tests/bats/37_auth_flows.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: 认证流——登录之后的真实可用性
  @REQ-M0-A3
  @REQ-M0-A4
  @REQ-M0-A6

  @REQ-M0-A3
  Scenario: auth: LDAP 服务账号 bind 正确口令成功，错误口令必须拒绝（反证）
    Given svc-platform-admin 的口令真值在部署机 .env
    When 用正确口令对 LDAP 做 bind，再用错误口令重做一次
    Then 正确口令 bind 成功，错误口令必须收到 INVALID_CREDENTIALS

  @REQ-M0-A3
  @REQ-M0-A6
  Scenario: auth: 组授权真源——docs-users 由 posixGroup 决定（svc-platform-dev 在内，svc-jira-dev 不在）
    Given LDAP 目录已初始化且 groups OU 存在
    When 查询 cn=docs-users 的 memberUid
    Then svc-platform-dev 在成员表里且 svc-jira-dev 绝不在

  @REQ-M0-A0
  @REQ-M0-A4
  Scenario: auth: 完整 OIDC 登录建立会话——会话内取受保护页放行，伪造会话必须回登录页（反证）
    Given svc-platform-dev 属授权组且靶子文件在 docs/ 里真实存在
    When 走 oauth2→Dex→LDAP→approval 完整登录后取受保护页，再用伪造 Cookie 取同一页
    Then 会话内拿到 200 内容，伪造会话必须被甩回 /oauth2/start 登录流

  @REQ-M0-A4
  Scenario: auth: Jenkins API 用 LDAP 凭据建 Job→触发构建→SUCCESS→删除（专用夹具+清理）
    Given svc-platform-admin 可经 Jenkins API 用 LDAP 凭据认证并持有 crumb
    When 建一个 echo freestyle 夹具 Job、触发构建并轮询结果，无论成败 teardown 都删夹具
    Then 构建结果是 SUCCESS，且夹具 Job 在用例结束后不复存在
