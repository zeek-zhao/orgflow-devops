# [06] M0 测试体系：每服务 bats 用例 + DinD 全容器化 + 镜像 digest 锁定

- **Issue**：#11
- **PR**：#13
- **分支**：`feat/11-bats-dind`
- **类型**：回溯重建（原文是一段话的派单 prompt，验收口径按当前仓库状态重写）
- **依赖**：#1–#5（栈要能起来）
- **token 预算**：约 20 万 token（本议题改动面最大）

## 目标

把测试从「纯逻辑」升级到「对着跑起来的服务断言」，并且换台机器也能跑。

三个终态：

1. **每个服务至少一条 bats 用例**，断言「服务真的能用」而不是「容器起来了」
2. **全部 docker 化**：宿主机只要求有 docker，不要求 python3 / bats / curl / ldap-utils
3. **所有镜像固定 digest**：compose 里 `image:` 一律 `@sha256:`，浮动 tag 清零

## 背景与取证

原状的问题：现有测试全是**纯逻辑/静态**测试（`test_render.py` / `test_bootstrap.py` /
`test_jobs.py` / `test_deploy.py` / `test_backup.py`），**没有一条用例对着跑起来的服务做断言**。后果：

- 「healthy」只证明进程活着，不证明端点真的对
- 改了 `routes.yaml` 或 compose，逻辑测试照样全绿，但栈已经坏了
- 测试依赖宿主机（python3、bats、ldap-utils、已装好的镜像），换台机器跑不了
- compose 用浮动 tag，今天能跑不代表下个月能跑

**已实测的技术前提（不要再重新假设）**

| 事实 | 值 / 结论 |
|---|---|
| docker / compose | 26.1.0 / v2.26.1，cgroup v2，overlay2 |
| 内核 | 6.8.0，嵌套 overlay2 可用 |
| `--privileged` | 可用 |
| noble apt 包 | `docker.io 29.1.3`、`docker-compose-v2 2.40.3`、`bats 1.10.0` 均可用 |
| `download.docker.com` | **不可达** → DinD 的 dockerd 必须用 apt 的 `docker.io`，不能用官方静态包 |
| Docker Hub | 本机**完全不可用**（`registry-1.docker.io` TLS rc=35，blob 反复 reset） |
| GHCR | 可用 |

**各服务断言的实测真值（照着写，不要猜）**

| 路径 / 操作 | 实测结果 |
|---|---|
| `GET /auth/ping` | `200`，body `OK` |
| `GET /jenkins`（未登录） | `302`，`Location` 指向登录入口 |
| `GET /dex/.well-known/openid-configuration` | `200`，JSON 含 `issuer` / `authorization_endpoint` / `token_endpoint` / `jwks_uri` / `userinfo_endpoint` |
| `GET /ldapadmin/` | `200`，HTML 含 `phpLDAPadmin` |
| `GET /nexus/` | `200` |
| `GET /nexus/service/rest/v1/status` | `200`，**body 为空**（只断言状态码） |
| `docker compose exec -T jenkins curl ... localhost:8080/login` | `200`（jenkins 未发布宿主端口，必须 exec 进网络内） |
| `docker compose exec -T router python3 -c "urllib.urlopen(.../healthz)"` | `200` |
| `ldapsearch -b dc=devops,dc=com -s sub "(objectClass=*)" dn \| grep -c ^dn:` | `33` |

## 范围

**新增**

| 文件 | 内容 |
|---|---|
| `tests/images.lock` | 机器可读单一真源：`key<TAB>ref<TAB>digest` |
| `tests/images.sh` | `ensure` / `harness-image` / `update` 子命令 |
| `tests/harness/Dockerfile` | `FROM ubuntu:24.04@sha256:...`，装 `docker.io` / `docker-compose-v2` / `bats` / `curl` / `jq` / `ldap-utils` |
| `tests/harness/entrypoint.sh` | 起 dockerd → 从宿主 docker 预灌镜像 → `compose up --no-build` → 健康闸门 → 跑 bats → 失败时 dump 日志 → `down -v` |
| `tests/bats/helpers/common.bash` | `gw_curl` / `http_code` / `http_header` / `compose_exec` / `assert_gw` / `gw_wait` |
| `tests/bats/00_stack.bats` | 策略用例：compose 里所有 image 带 digest、digest 与 `images.lock` 一致、服务齐全 |
| `tests/bats/{10_ldap,11_ldapadmin,12_dex,13_oauth2_proxy,14_caddy,15_router,16_jenkins,17_nexus}.bats` | 每服务一条 |
| `docs/M0-测试体系.md` | 怎么跑、怎么加用例、怎么升 digest |

**改**

| 文件 | 改法 |
|---|---|
| `docker-compose.yml` | 所有 `image:` 改 `@sha256:` 锁定；`build:` 的基座 Dockerfile 也锁 |
| `services/router/render.py` | 增加 catch-all 兜底（未匹配路径不再是空 200） |
| `tools/jjb/Dockerfile` | 基座锁 digest |
| `Makefile` | `test-bats`（一键）、`images-lock`（重新生成 lock 表） |

**不做**

- 不做 CI 与 GHCR 推送（下一个议题 #12）
- 不引入 pytest / testinfra 等第二套框架
- 不改服务行为（除了未匹配路径的兜底）

## 验收

- [ ] `make test-bats` → 一条命令跑完，**全部 .bats pass**，退出码 `0`
- [ ] `grep -nE "^\s+image:\s*[^ ]+:[^@ ]+$" docker-compose.yml` → **无输出**（浮动 tag 清零）
- [ ] `docker image inspect orgflow/m0-test:24.04-v1` 的历史里能看出基座为 `ubuntu:24.04@sha256:...`
- [ ] 宿主机不装 bats / python3 也能跑（用例只在容器内执行）——用干净容器验证
- [ ] 跑完 `docker ps` 无残留、`docker volume ls` 无残留测试卷
- [ ] 反证：删掉 `routes.yaml` 里 `nexus` 那条 route 并重启 router → `14_caddy.bats` **必须 fail**；恢复后重新全绿（贴两次输出）
- [ ] 反证：把某个 `image:` 的 `@sha256:` 去掉 → `00_stack.bats` **必须 fail**
- [ ] 反证：把 `images.lock` 里某个 digest 改错 → `00_stack.bats` **必须 fail**

## 禁止事项

- 不得让断言依赖内部实现细节：只断言对外可观测行为（HTTP 状态 / 跳转目标 / JSON 字段名 / LDAP 条目数 / 渲染产物结构）
- 不得在 DinD 起不来时静默跳过：起不来就打印 `dockerd` 日志并非 0 退出
- 不得为了让用例过而放宽断言
- 不得引入第二套测试框架
- 不得自行合并 PR

## 依赖与前置

- [ ] `docker run --privileged --rm ubuntu:24.04 true` → 退出码 `0`
- [ ] 宿主机已缓存或被允许拉取 `tests/images.lock` 里的全部镜像
- [ ] `docker compose config -q` → 退出码 `0`

## 交付物

- [ ] 分支 `feat/11-bats-dind`
- [ ] PR 正文含：做了什么 / 每服务断言表 / 反证两次输出 / 未验证项
- [ ] `docs/M0-测试体系.md` 必须写「怎么升 digest 的三步」

## 当年实测（PR #13 记录）

| 项 | 结果 |
|---|---|
| `make test-bats` | 9 个用例文件全 pass |
| 浮动 tag 扫描 | 无输出 |
| DinD | 起得来，跑完 `down -v` 无残留 |

## 风险与处置（当年结论）

| 风险 | 处置 |
|---|---|
| DinD 内 dockerd 起不来 | entrypoint 里起不来就打印日志并非 0 退出，不静默跳过 |
| 拉不到镜像导致 `up` 失败 | entrypoint 从宿主 `/var/run/docker.sock` 预灌（`docker save \| docker load`），只灌 inner 缺失的 |
| 断言过拟合内部实现 | 只断言对外可观测行为 |
| 固定 digest 后升级麻烦 | `images.lock` 单一真源 + `make images-lock` 生成 + 文档写升级三步 |

## 与本卡的偏离

- 当年 8 个服务 9 个用例文件；ADR-13 之后多了 `19_dns.bats`（dnsmasq）与 `20_tls.bats`（内部 CA），
  现在是 12 个用例文件 / 21 条用例
- 当年的 `14_caddy.bats` 断言路径前缀；ADR-13 后改为断言域名站点
- 当年 `/nope` 的兜底是 catch-all；现在改为 per-site 404（域名路由下每个站点自己兜底）
