# Feature: 网关组授权 ACL

  行为真源：与 tests/bats/36_gateway_acl.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: 网关组授权 ACL
  @REQ-M0-A3
  @REQ-M0-A5
  @REQ-M0-A6

  @REQ-M0-A5
  Scenario: gateway acl: forward_auth 只剩文档站 1 处,jenkins/ldapadmin 已摘
    Given Caddyfile 已按 #86 调整
    When 统计 forward_auth 出现处
    Then 只剩文档站 1 处

  @REQ-M0-A3
  Scenario: gateway acl: oauth2-proxy 参数收紧(allowed-group/单域 cookie/无发布端口)
    Given oauth2-proxy 配置就绪
    When 检查 allowed-group/cookie/端口
    Then 参数收紧且无发布端口

  @REQ-M0-A6
  Scenario: gateway acl: 组成员(svc-platform-dev)完成 OIDC 后访问文档站放行
    Given svc-platform-dev 属授权组
    When 完成 OIDC 登录后访问文档站
    Then 放行

  @REQ-M0-A6
  Scenario: gateway acl: 反证——口令错时不得拿登录页的 200 冒充放行
    Given 测试凭据准备就绪
    When 用错误口令走登录流
    Then 不得拿登录页 200 冒充放行（反证）

  @REQ-M0-A6
  Scenario: gateway acl: 非组成员(svc-jira-dev)完成 OIDC 后必须被拒
    Given svc-jira-dev 不属授权组
    When 完成 OIDC 后访问文档站
    Then 必须被拒
