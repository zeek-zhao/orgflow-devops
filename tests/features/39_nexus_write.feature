# Feature: Nexus 写路径
  行为真源：与 tests/bats/39_nexus_write.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。
Feature: Nexus 写路径
  @REQ-M0-B9
  Scenario: nexus: pypi 写路径——REST 上传 wheel→匿名组仓索引→按索引下载 200
    Given pypi-hosted 仓库存在且管理员凭据在部署机 .env
    When 构造最小 wheel 上传后在组仓 simple 索引解析出下载地址
    Then 上传返回 204，匿名可解析索引并按 href 下载到非空 wheel
  @REQ-M0-B9
  Scenario: nexus: docker connector——匿名 401 质询，凭据后 catalog 200
    Given docker connector 域名路由到 Nexus 且匿名读被协议质询保护
    When 无凭据与有凭据分别请求 /v2/_catalog
    Then 无凭据必须 401，凭据后返回含 repositories 的 JSON
