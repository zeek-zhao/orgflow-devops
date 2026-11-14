# Feature: dnsmasq 域名解析

  行为真源：与 tests/bats/19_dns.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: dnsmasq 域名解析
  @REQ-M0-D4

  @REQ-M0-D4
  Scenario: dns: dnsmasq 把整个网关域名段解析到 Caddy 的固定 IP
    Given dnsmasq 已运行
    When 解析全部网关子域
    Then 全部指向 Caddy 固定 IP

  @REQ-M0-D4
  Scenario: dns: 容器内能用域名互访（服务端到服务端不绕公网）
    Given 服务容器已运行
    When 容器内按域名互访
    Then 域名互访成功，不绕公网

  @REQ-M0-D4
  Scenario: dns: 服务名仍然可解析（dnsmasq 转发给 Docker 内嵌 DNS）
    Given dnsmasq 已运行
    When 解析 Docker 服务名
    Then 服务名可解析（转发内嵌 DNS）

  @REQ-M0-D4
  Scenario: dns: nexus 容器也把 dnsmasq 当 resolver（不是 Docker 内嵌 DNS）
    Given nexus 容器已由 job 创建
    When 检查其 resolver 配置
    Then resolver 是 dnsmasq 而非 Docker 内嵌 DNS

  @REQ-M0-D4
  Scenario: dns: 固定 IP 表与架构图一致（排查时按 IP 定位容器）
    Given compose 与文档就绪
    When 对照 IP 表与架构图
    Then 固定 IP 与架构图一致
