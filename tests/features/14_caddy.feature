# Feature: Caddy 网关站点

  行为真源：与 tests/bats/14_caddy.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: Caddy 网关站点
  @REQ-M0-C2
  @REQ-M0-D3

  @REQ-M0-C2
  @REQ-M0-D3
  Scenario: caddy: ten domain sites, authentication, per-site 404 and Nexus API (#117 #62)
    Given routes.yaml 十个站点已渲染
    When 逐站点请求并验证认证与 404
    Then 站点数与配置一致，认证/404/Nexus API 行为正确

  @REQ-M0-C2
  Scenario: caddy: 站点地址全部是域名，旧路径入口已删除 (#117 #62)
    Given Caddyfile 已渲染
    When 检查站点地址形式
    Then 全部是子域名，旧路径入口不存在

  @REQ-M0-C2
  Scenario: caddy: HTTP 端口只做跳转，未知域名没有站点承接
    Given Caddy 监听 80/443
    When 请求 HTTP 与未知域名
    Then HTTP 只 308 跳转，未知域名无站点承接
