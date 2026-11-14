# Feature: GHCR 公开发布物

  行为真源：与 tests/bats/18_public.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: GHCR 公开发布物
  @REQ-M0-B8

  @REQ-M0-B8
  Scenario: public: 14 个 GHCR 包都能匿名取到 manifest（无需登录）
    Given GHCR 包已发布
    When 匿名请求各包 manifest
    Then 14 个包全部可匿名取得

  @REQ-M0-B8
  Scenario: public: 反证——不存在的包必须拿不到 200（否则上一条是假绿）
    Given 上一条匿名拉取通过
    When 请求不存在的包
    Then 必须拿不到 200，证明上一条不是假绿
