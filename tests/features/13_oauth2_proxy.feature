# Feature: oauth2-proxy 网关认证

  行为真源：与 tests/bats/13_oauth2_proxy.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: oauth2-proxy 网关认证
  @REQ-M0-A0
  @REQ-M0-A4

  @REQ-M0-A0
  @REQ-M0-A4
  Scenario: oauth2-proxy: ping and unauthenticated OIDC redirects across domains
    Given oauth2-proxy 已部署
    When 请求 ping 与未认证受保护页
    Then ping 200；未认证跨域 302 到 OIDC
