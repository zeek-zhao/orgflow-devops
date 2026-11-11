# M0-D · 底座与运维（REQ-M0-D*）

> 需求基线 · DOC-R-008 ｜ 状态：approved ｜ 负责人：zeek.zhao ｜ 评审日期：2026-11-11 ｜ 复审：12 个月
> 本域 7 条，覆盖 Issue #1 #4 #5 #47 #61 #62 #116（6 关闭 / 1 open）。
> 规则见 [需求基线入口](README.md)：**要求与判据冻结，现状与证据可变**；判据前的 ⚠ 表示干净 clone 上复现不出来。

## 1. 需求表

| 编号 | 要求 | 验收判据 | 现状 | 证据 |
|---|---|---|---|---|
| **REQ-M0-D1** | 改 `config/routes.yaml` 后 Caddy 热加载生效、旧路由不中断；渲染失败时保持上一版继续服务，不把网关弄挂 | `bats tests/bats/15_router.bats` 绿；反证：往 `routes.yaml` 写一条非法路由 → 渲染失败、Caddy 仍在服务旧配置（旧路由状态码不变） | 已实现 | [#1](https://github.com/zeek-zhao/orgflow-devops/issues/1) · PR #24 #73 #109 |
| **REQ-M0-D2** | 路由可经 HTTP API 注册 / 查询 / 删除；`routes.yaml` 仍是**唯一真源**，API 只是写入口；非法输入必须 400 且**不改文件** | `bats tests/bats/34_router_api.bats` 绿；反证：`POST` 一条 `host` 为空的 route → 400，且 `routes.yaml` 的 sha256 前后不变 | 已实现 | [#61](https://github.com/zeek-zhao/orgflow-devops/issues/61) · PR #79 #81 #98 #99 |
| **REQ-M0-D3** | 一条命令把内部 CA 根证书装进任意机器信任库；拉不到证书必须非零退出并打印原因 | `bats tests/bats/35_ca_distribution.bats` 绿；反证：把网关地址指向不存在的 IP → 命令必须非零退出，不得静默成功 | 已实现 | [#62](https://github.com/zeek-zhao/orgflow-devops/issues/62) · PR #101 |
| **REQ-M0-D4** | 干净机器上一条命令从零起整套底座，并通过健康检查与端点自检；缺 `.env` 时自动派生并生成密钥，不打印密钥 | `python3 scripts/test_deploy.py` 绿；`bats tests/bats/00_stack.bats tests/bats/32_bootstrap_scripts.bats` 绿 | 已实现 | [#4](https://github.com/zeek-zhao/orgflow-devops/issues/4) · PR #9 #110 #111 |
| **REQ-M0-D5** | 备份产出可恢复包（`.tgz` + `.sha256` + `.meta`），保留策略生效；卷不存在或备份失败必须非零退出，不产出「成功」的空包 | `python3 scripts/test_backup.py` 绿；`bats tests/bats/30_backup_restore.bats tests/bats/33_restore_guards.bats` 绿；反证：`RETENTION_DAYS=0` 必须被拒绝而非静默不清理 | 已实现 | [#5](https://github.com/zeek-zhao/orgflow-devops/issues/5) · PR #10 #24 #97 #118 |
| **REQ-M0-D6** | Windows 侧 hosts 增删与根证书安装脚本入库；`.bat` 为 GBK+CRLF、`.ps1` 为 UTF-8 带 BOM+CRLF；删除脚本能干净回滚 | 机械部分：`ls tools/win-acceptance/{Set-OrgflowHosts.ps1,Import-OrgflowRootCa.ps1,Test-OrgflowAcceptance.ps1,acceptance.bat}` 全部在位；⚠ 主判据需人工：干净 Windows 上跑「加 hosts（6 条，含 `auth`）→ 装证书 → 5 站点无警告 → 删 hosts 干净回滚」 | 已实现 | [#47](https://github.com/zeek-zhao/orgflow-devops/issues/47) · PR #49 |
| **REQ-M0-D7** | Jenkins 视图按用途分类、接入第二台执行节点（SSH 预接入）、Ansible 远程部署占位 | ⚠ 判据缺失：M0 关闭时未开工，没有可执行的验收命令 | 未实现 · 转入 M1 | [#116](https://github.com/zeek-zhao/orgflow-devops/issues/116)（open） |

## 2. 要点与坑

### D1：热加载的是 router 容器，不是宿主

「改路由不重启」这条能力的实现位置容易搞错：**是 `router` 容器 watch `routes.yaml` 后调 Caddy admin 接口**，不是从宿主跑 `make render`。宿主够不到 `caddy:2019` 这个内部地址。

所以 `make render` 在宿主上只用于「看一眼渲染结果」，真正的热加载由容器完成。判据写成 `bats 15_router.bats` 而不是「跑一次 `make render`」，就是为了不把这两件事混起来。

### D2：防第二真源

API 能写 `routes.yaml`，很容易做成「API 自己维护一份内存路由」。要求里显式禁止了这一点：

- 文件仍是唯一真源，API 只是它的写入口；
- 非法输入必须 **400 且在写文件之前就拒绝** —— 判据用 sha256 前后一致来证明「真的没写」，而不是「写进去再渲染失败」。

这条反证是整个 D2 的关键：**只看状态码 400 分不清是「校验拦住了」还是「写坏了才报错」**。

### D4：`.env` 派生与不打印密钥

`make deploy` 在 `.env` 不存在时从 `.env.example` 派生，生成 Jenkins / LDAP 管理员口令、OAuth2 client secret、cookie secret，权限 `0600`，**只提示「已写入 .env」，不打印值**。

已有持久化 LDAP 数据时必须用与原数据匹配的管理员口令，随机新口令不会重置已有目录 —— 这条限制没写进判据，因为它在干净环境上验不出来，只能在有数据的环境上验。

### D5：`RETENTION_DAYS=0` 是拒绝而不是「不清理」

要求里写的是「保留策略生效」。落地时把 `0` 定义成**明确拒绝**（非零退出），因为「静默不清理」和「清理策略没生效」在日志上无法区分。

`.sha256` 与 `.meta` 不是附属物：缺任一即视为备份不完整，恢复链路会读不到校验值。

### D6：Windows 的三个编码硬约束不是洁癖

- `.bat` 必须是 **GBK(936) + CRLF**：LF 的 `.bat` 会让 `goto` / `if` 块解析错乱；
- `.ps1` 必须是 **UTF-8 带 BOM + CRLF**：无 BOM 的中文会被按 ANSI 读成乱码；
- `certutil` 失败返回**负数 HRESULT**，cmd 的 `if errorlevel 1` 只认非负 → 会误判成功。所以证书判断一律走 `Cert:\LocalMachine\Root` 枚举，不看 `certutil` 的退出码。

这三条在仓库里没有任何自动化断言，属于**只能靠人守的约束**。这是本域最脆的一格。

### D7：为什么和 B9 一样标「转入 M1」

同 B9：M0 已于 2026-11-01 关闭，但 #116 仍挂在 M0 里程碑上。需求基线如实写「未实现 · 转入 M1」，不为了让里程碑好看而改成「已降级」。

缺口是具体的：Jenkins 只有 1 个视图 `all`；自定义节点只有 `orgflow-docker` 一个（没有单核节点、没有 SSH 预接入节点）；仓库内**没有任何 ansible 文件**。
