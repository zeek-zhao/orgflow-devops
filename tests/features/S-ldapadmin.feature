Feature: LDAP Admin 管理端
  作为运维
  我要一个能列目录、连不上也不崩的 Web 端
  以便管理用户

  Scenario: 正常访问
    Given ldap 可达
    Then 页面 200 且能展开 base DN

  Scenario: 降级不崩
    Given ldap 不可达
    Then 显示登录页并重试，容器仍 healthy
