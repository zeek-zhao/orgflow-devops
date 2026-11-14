# Feature: Homepage 服务卡片
  行为真源：与 tests/bats/41_homepage_cards.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。
Feature: Homepage 服务卡片
  @REQ-M0-C1
  Scenario: homepage: 服务卡片逐链接实访——全部可达且无 5xx/死链
    Given /api/services 里的服务卡片是内网入口、/api/bookmarks 全部是外链文档
    When 逐个实访内网卡片链接并检查书签 URL 格式
    Then 卡片链接全部落在 200/301/302/401/403 且无 000/5xx，书签全部是完整 https URL
