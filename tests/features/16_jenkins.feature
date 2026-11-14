# Feature: Jenkins 登录链路

  行为真源：与 tests/bats/16_jenkins.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: Jenkins 登录链路
  @REQ-M0-A4

  @REQ-M0-A4
  Scenario: jenkins: internal login is ready but the gateway requires authentication
    Given Jenkins 已就绪
    When 内网直连与走网关分别请求
    Then 内网 /login 200；网关侧未认证被拒
