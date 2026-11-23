Feature: dnsmasq 单服务
  作为最小系统
  我要 *.DOMAIN 统一解析到 Caddy
  以便所有站点走唯一入口

  Scenario: 容器健康
    Given dnsmasq 容器已单起
    Then healthcheck 为 healthy

  Scenario: 通配解析
    When 查询 home.<DOMAIN>
    Then 返回 Caddy IP .10
    And 未定义子域同样返回 .10
    And 非法域返回 NXDOMAIN

  Scenario: 日志无错误
    Given dnsmasq 容器运行中
    Then 日志不含 ERROR
