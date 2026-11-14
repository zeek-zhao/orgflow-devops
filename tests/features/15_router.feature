# Feature: router 渲染与热加载

  行为真源：与 tests/bats/15_router.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: router 渲染与热加载
  @REQ-M0-D1
  @REQ-M0-D2

  @REQ-M0-D1
  @REQ-M0-D2
  Scenario: router: health, idempotent output and rejected invalid input
    Given router 容器就绪
    When 请求 healthz、重复渲染、喂非法配置
    Then health 正常，输出幂等，非法输入被拒且文件不变
