# Feature: CA 证书分发

  行为真源：与 tests/bats/35_ca_distribution.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: CA 证书分发
  @REQ-M0-D3

  @REQ-M0-D3
  Scenario: ca 站点: root.crt 与安装脚本都能经网关拉取，证书主题正确
    Given ca 站点已配置
    When 经网关拉 root.crt 与安装脚本
    Then 均可拉取且证书主题正确

  @REQ-M0-D3
  Scenario: ca-install.sh 远程模式: 干净容器一条命令装根证书并复验通过
    Given 干净容器无内部 CA
    When 远程模式执行 ca-install.sh
    Then 一条命令装好并复验通过
