# orgflow-devops 部署清单（占位骨架，未接真实目标主机）

> **边界（用户裁决 2026-11-11）**：本目录只落 Ansible 的 inventory + playbook 骨架，
> 并在本机跑一次 dry-run 证明它能被解析、任务能展开。**不接任何真实远程主机，
> 不虚构远程部署成功，不写远端 cron、不建计划任务。**
>
> `inventory/hosts.yml` 里只有一台 `loopback-placeholder`，`ansible_connection: local`、
> `ansible_host: 127.0.0.1`。这是为了让 `--check` 能完整跑完而不触碰外部机器。
> 换成真实目标时必须同时改这三处，否则所有任务都会打在本机上。

## 目录

| 文件 | 作用 |
|---|---|
| `inventory/hosts.yml` | 主机清单。当前只有 loopback 占位 |
| `playbooks/deploy.yml` | 部署主链路占位：目录 → 配置文件 → 版本标记 |
| `ansible.cfg` | 只设 inventory 与超时，不关 `host_key_checking` |

## 本机 dry-run

`ansible.cfg` 在本目录下，从仓库根跑时不会被自动发现，所以显式用 `ANSIBLE_CONFIG`
指过去。工具是临时安装的 `ansible-core 2.21.6`（WSL 用户目录，不进仓库、不碰 213）。

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/deploy.yml --check --diff
```

`--check` 不会写任何文件；输出里出现 `changed` 是**预期**（表示「如果真跑会改什么」），
不是失败。判据看的是：所有 task 都被执行到、没有 `UNREACHABLE` / `FAILED`。

**2026-11-11 实测原始输出**（省略 debug 正文与 diff 明细）：

```
PLAY [Orgflow 部署占位（dry-run 用）] ******************************************

TASK [声明目标（占位说明，不是真实主机）] **************************************
ok: [loopback-placeholder]

TASK [部署根目录应存在] ********************************************************
--- before
+++ after
@@ -1,4 +1,4 @@
-    "state": "absent"
+    "state": "directory"
changed: [loopback-placeholder]

TASK [部署标记文件应为期望版本] ************************************************
--- before
+++ after: /srv/orgflow-devops/RELEASE
@@ -0,0 +1 @@
+placeholder-0.0.0
changed: [loopback-placeholder]

TASK [列出期望的发布物（真实部署时由 Jenkins job 提供）] ***********************
ok: [loopback-placeholder]

PLAY RECAP *********************************************************************
loopback-placeholder       : ok=4    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

`ANSIBLE_RC=0`。**这只是语法与任务展开的验证，不是一次成功的远程部署。**

## 接真实目标主机时要做什么（复活条件）

1. 把 `inventory/hosts.yml` 的 `loopback-placeholder` 换成真主机，去掉
   `ansible_connection: local`，配好 `ansible_user` 与 SSH 凭据（凭据走环境变量或
   vault，**不进仓库**）。
2. `playbooks/deploy.yml` 里 `deploy_root`、文件名、版本号改成真实值；当前是示例。
3. 先在**一台**非生产机上不带 `--check` 跑一次，贴控制台输出；再谈批量。
4. 需要定时执行时走 Jenkins job，不写远端 cron（D19）。

## 相邻边界

- **Gerrit Trigger 插件已装但未配置服务器**（`services/jenkins/plugins.txt`），
  仓库里没有 Gerrit 端点、没有凭据，插件不会连任何外部 Gerrit 实例。
- 面板与 SSH 节点由 `config/jenkins.yaml` 的 JCasC 声明，重部署后仍存在；
  Ansible 与 JCasC 是两条独立的路径，本目录不负责建 Job 或改 Jenkins 配置。
