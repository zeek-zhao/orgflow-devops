# Feature: Dex OIDC 提供方

  行为真源：与 tests/bats/12_dex.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: Dex OIDC 提供方
  @REQ-M0-A4

  @REQ-M0-A4
  Scenario: dex: discovery, signing keys and health endpoint on the dex subdomain
    Given dex 子域路由已配置
    When 请求 discovery/keys/health
    Then 三者均可用且格式合法
