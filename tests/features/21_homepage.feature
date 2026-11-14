# Feature: Homepage 统一入口

  行为真源：与 tests/bats/21_homepage.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: Homepage 统一入口
  @REQ-M0-C1

  @REQ-M0-C1
  Scenario: homepage: 统一入口可达，且服务卡片都在
    Given homepage 已部署
    When 请求首页并解析服务卡
    Then 入口可达且服务卡片齐备

  @REQ-M0-C1
  Scenario: homepage: 卡片链接用的是配置里的域名，模板没有残留
    Given homepage 配置已渲染
    When 检查卡片链接域名
    Then 链接用配置域名，无模板占位残留

  @REQ-M0-C1
  Scenario: homepage: 每个书签都必须有 href（缺了整页会报 Invalid URL）
    Given 书签配置已加载
    When 逐书签检查 href
    Then 每个书签都有 href
