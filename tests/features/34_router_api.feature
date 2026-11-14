# Feature: 路由 API

  行为真源：与 tests/bats/34_router_api.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: 路由 API
  @REQ-M0-D2

  @REQ-M0-D2
  Scenario: router api: POST 一条路由 → 文件/Caddyfile/Caddy 三处全生效，不重启任何容器
    Given router API 就绪
    When POST 一条合法路由
    Then routes.yaml/Caddyfile/Caddy 三处生效且不重启容器

  @REQ-M0-D2
  Scenario: router api: 非法输入 400，routes.yaml 与 Caddyfile 原封不动（#61 关键反证）
    Given router API 就绪
    When POST 非法输入
    Then 返回 400 且两个文件原封不动

  @REQ-M0-D2
  Scenario: router api: GET /routes 是合法 JSON；/healthz 照常工作
    Given router API 就绪
    When GET /routes 与 /healthz
    Then JSON 合法，healthz 正常
