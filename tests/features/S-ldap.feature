Feature: OpenLDAP 目录
  作为统一身份源
  我要匿名拒、管理员成功、ACL 生效
  以便下游服务安全绑定

  Scenario: 匿名访问被拒
    When 匿名 ldapsearch
    Then 返回 Insufficient access

  Scenario: 管理员访问成功
    When 用管理员 DN 和口令 ldapsearch
    Then 成功返回目录条目

  Scenario: 最小暴露
    Then 宿主不映射 389 端口
