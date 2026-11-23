Feature: Router 路由注册
  作为运维
  我要改 routes.yaml 即生效、不改 Caddy 配置真源
  以便安全热更新站点

  Scenario: 健康
    Then /healthz 200

  Scenario: 热更新
    When 改 routes.yaml 并 make routes
    Then 30s 内新域 200，不重启 Caddy

  Scenario: 坏配置保护
    Given 坏 upstream
    When /render
    Then 422 且不 reload

  Scenario: 降级
    Given Caddy 不可达
    When /render
    Then 503 而非进程退出
