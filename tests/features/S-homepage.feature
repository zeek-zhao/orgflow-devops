Feature: HomePage 统一面板
  作为用户
  我要一屏看到所有服务入口
  以便快速跳转

  Scenario: 静态页可访问
    Then 页面 200 且卡片 ≤5 张

  Scenario: 改配置免重启
    When 修改 bookmarks.yaml
    Then 无需重启即生效（每次请求重读）

  Scenario: 反证——不静默丢项
    Given cards 配成映射而非列表
    Then 返回 500 并给出原因，不静默丢弃
