# Feature: Nexus 仓库服务

  行为真源：与 tests/bats/17_nexus.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: Nexus 仓库服务
  @REQ-M0-B7

  @REQ-M0-B7
  Scenario: nexus: 网关 200、status API 200、容器健康且落在 172.31.0.21
    Given nexus-deploy 已执行
    When 请求网关与 status API
    Then 均 200，容器 healthy 且固定在 172.31.0.21

  @REQ-M0-B7
  Scenario: nexus: 由 nexus-deploy 创建，且不在 compose 服务列表里
    Given compose 配置已渲染
    When 检查 compose 服务列表与容器来源
    Then nexus 不在 compose，由 nexus-deploy 创建

  @REQ-M0-B7
  Scenario: nexus: 重跑 nexus-deploy 幂等，不重建容器
    Given nexus 容器已存在
    When 重跑 nexus-deploy
    Then 容器 ID 不变，只复用不重建

  @REQ-M0-B7
  Scenario: nexus: 初始密码文件已删除，配置的密码能登录
    Given nexus-deploy 已完成
    When 确认初始密码文件不存在并用配置密码登录
    Then 初始文件已删，配置密码可登录
