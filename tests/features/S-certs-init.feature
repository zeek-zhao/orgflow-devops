Feature: certs-init 内部 CA 签发
  作为最小系统
  我要一次签发、多次幂等的内部 CA
  以便 Caddy 有受信任证书

  Scenario: 首次签发
    Given 空 CA 卷
    When certs-init 运行
    Then exit 0 且卷内有 ca.crt + site.crt
    And site.crt SAN 含 *.DOMAIN

  Scenario: 二次幂等
    Given CA 卷已有未过期证书
    When certs-init 再次运行
    Then 跳过重签（FORCE=1 才重签）
