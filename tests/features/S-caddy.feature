Feature: Caddy 唯一入口
  作为最小系统
  我要唯一的 80/443 入口按 Host 分站点
  以便各服务共用一个 TLS 终点

  Scenario: bootstrap 启动
    Given 无证书或已有证书
    When caddy 启动
    Then healthcheck healthy 且 Admin API 200

  Scenario: HTTP 跳转
    When 访问 http://<host>/
    Then 返回 308 到 https

  Scenario: 无证书降级
    Given CA 卷为空
    When caddy 启动
    Then 生成 bootstrap 自签占位，仍能起（不崩）
