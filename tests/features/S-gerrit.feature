Feature: Gerrit 代码评审服务（M2.1）
  作为研发团队
  我要一个 Docker 化的 Gerrit 提供 LDAP 登录与 Git 托管
  以便代码走评审流而非直接推主干

  Scenario: 容器与镜像门禁
    Given gerrit 官方镜像由 CI 中转推 GHCR 且 digest 钉在 images.lock
    When of-gerrit 容器启动
    Then healthcheck healthy 且 REST /version 返回 3.9.x

  Scenario: Web 入口可达
    Given Funnel :8443 → Caddy :18085 → gerrit:8080 已映射
    When 公网访问 https://<host>:8443/
    Then 返回 200 且页面为 Gerrit 3.9

  Scenario: LDAP 登录（M0 ACL 匿名拒读）
    Given gerrit.config 用 ldap.username/password 做查询 bind 且 supportAnonymous=false
    When 用 LDAP 账号 zeek.zhao 登录
    Then 认证成功并自动建号（首次登录入 Administrators）
    And LDAP 端观察到 cn=admin 的 BIND 成功，非匿名 BIND dn=""

  Scenario: 口令渲染安全
    Given LDAP 口令经 entrypoint 用 python3 str.replace 渲染（不经 sed）
    When 口令含 | & \ / 等特殊字符
    Then gerrit.config 中 password 值字面正确且 ${username} 变量未被替换

  Scenario: 配置正确性
    Given 官方镜像实际运行用户为 gerrit(uid1000)
    Then gerrit.config [container] user = gerrit（非 gerrit2）

  Scenario: HTTP clone
    Given 已登录账号有读权限
    When git clone https://<host>:8443/All-Projects
    Then clone 成功生成 .git 目录

  Scenario: SSH 可达性
    Given 宿主 29418 已发布（仅供 tailnet，公网不转 TCP）
    When tailnet 设备用已配置 SSH key 连接
    Then gerrit ls-projects 可列出项目
    # 注：SSH key 属管理员初始化项，未配置时此项为待办，不虚报通过

  Scenario: 评审流（待初始化）
    Given 业务仓 orgflow-devops 已建且 HEAD 指向 main
    When git push HEAD:refs/for/main
    Then 生成 Change
    # 注：需管理员 HTTP password/SSH key 与建仓，当前仅有 All-* 系统库，属待办

  Scenario: 匿名项目列表口径
    Given cgit 采用公开策略且 /projects/?d 匿名可读
    Then 该行为为既定公开视图，写入文档而非视为缺陷
