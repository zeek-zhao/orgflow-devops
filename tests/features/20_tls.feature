# Feature: TLS 证书链

  行为真源：与 tests/bats/20_tls.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: TLS 证书链
  @REQ-M0-D3

  @REQ-M0-D3
  Scenario: tls: 每个站点都签出对应域名的证书，签发者是 Caddy 内部 CA
    Given 各站点已配置
    When 对每站点做 TLS 握手
    Then 证书域名匹配，签发者为 Caddy 内部 CA

  @REQ-M0-D3
  Scenario: tls: 导出的根证书能校验整条链（不带 -k 也通）
    Given 根证书已导出
    When 用根证书校验站点链
    Then 整链校验通过，无需 -k

  @REQ-M0-D3
  Scenario: tls: 不信任内部 CA 时握手必须失败（证明不是公共证书）
    Given 系统未信任内部 CA
    When 不装 CA 直接握手
    Then 校验必须失败，证明不是公共证书
