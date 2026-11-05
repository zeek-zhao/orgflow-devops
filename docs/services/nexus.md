# nexus

制品仓库。存 Maven / npm / docker 等构建产物。

> **★ 它不在 `docker-compose.yml` 里。** 2026-11-01（#46）起，Nexus 的容器创建和初始化
> 全部由 Jenkins job **`nexus-deploy`** 负责。所以 `docker compose ps` 看不到它、
> `docker compose logs nexus` 会报「no such service」，这些**都不是故障**。
> 为什么要移出去：Nexus 首次启动要 2 分钟以上，而 compose 的 `depends_on` 会拖住整个栈；
> 移出去之后 `make deploy` 只要 30 秒，Nexus 在后台慢慢起。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-nexus`（`docker run` 创建，不是 compose 命名） |
| 固定 IP | `172.31.0.21`（job 里显式 `--ip`） |
| 网络别名 | `nexus`（job 里显式 `--network-alias`，`docker run` 不会自动把容器名当别名） |
| 端口 | `8081`（容器内，不发布到宿主） |
| 镜像 | `sonatype/nexus3:3.92.2@sha256:a32ae23e…` |
| 卷 | `orgflow-devops_nexus_data` → `/nexus-data`（**写全名**，见下） |

## 入口与依赖

- **入口**：`https://nexus.<domain>`，**不需要登录**（`routes.yaml` 里没有 `auth: true`）
- **依赖谁**：`dnsmasq`（job 里显式 `--dns 172.31.0.2`，否则退回 Docker 内嵌 DNS，
  解析不了 `*.<domain>`）、`orgflow` 网络（job 前必须先 `make deploy` 把网络建出来）
- **被谁依赖**：无。Jenkins 的 Job 可以把产物推到它，但不是启动依赖

首次启动要 **2 分钟以上**（要初始化 OrientDB 和内置仓库）。job 里轮询
`/service/rest/v1/status` 直到 200，超时让 job 红 —— 这是唯一的就绪判据，
因为 `docker run` 没有 compose 的 healthcheck。

## 部署与配置

**不是 `docker compose up`，是跑 Jenkins job：**

```sh
# 213 上，先确保底座在
USE_GHCR=1 make deploy
# 推 job（首次或 job 定义变了才需要）
make jobs
# 触发（Jenkins UI 或 API 都行）
# → job/nexus-deploy/buildWithParameters
```

job 做的事（`config/job_definitions/nexus/nexus-deploy.yaml`）：

1. 检查 `orgflow` 网络在不在（不在就报「先跑 make deploy」并失败）
2. 容器已存在且 running → **复用，不重建**
3. 不存在 → `docker run -d --name of-nexus --network orgflow --ip 172.31.0.21
   --network-alias nexus --dns 172.31.0.2 -v orgflow-devops_nexus_data:/nexus-data <image>`
4. 轮询 `/service/rest/v1/status` 到 200（超时则 job 红）
5. 改密：`POST /service/rest/v1/security/users/admin/change-password`，
   **`Content-Type: text/plain`，body 就是新密码本身**（不是 JSON —— 写 JSON 会 415）
6. 删 `/nexus-data/admin.password`

**幂等**：重跑 job 不会重建容器，也不会重复改密（密码已生效就跳过）。
判据是「容器已存在（running），复用」+「密码已生效，跳过改密」两行日志。

| 位置 | 作用 |
|---|---|
| `orgflow-devops_nexus_data` 卷 | 全部状态：仓库、用户、配置。**备份只保这个卷** |
| `/nexus-data/admin.password` | 首次启动生成的 admin 初始密码，**job 改密后会删掉** |

> ⚠️ **卷名必须写全 `orgflow-devops_nexus_data`**。写成 `nexus_data` 会落到一个匿名卷，
> 表现是「数据看起来没了」—— 实际上数据还在旧卷里，只是新容器挂了个空的。
> 动手前先 `docker volume ls | grep nexus_data` 记下全名。

## 关键环境变量

| 变量 | 用途 |
|---|---|
| `NEXUS_ADMIN_ID` | job 改密时用的账号（默认 `admin`） |
| `NEXUS_ADMIN_PASSWORD` | job 改密时设的新密码 |

这两个在 `.env` 里，由 job 读取。**除这两个之外没有任何业务变量注入** ——
需要调的都在 `nexus_data` 里的配置文件，或者界面上的 `Admin → System`。

## 排查步骤

**1. 容器在吗、健康吗**

```sh
docker ps -f name=of-nexus --format '{{.Names}}\t{{.Status}}'
```

> 用 `docker ps` 而不是 `docker compose ps` —— 它不在 compose 里。

`docker run` 没有 healthcheck，所以状态只会是 `Up N minutes`，没有 `(healthy)`。
**这不是缺陷**，就绪判据用下一步的状态 API。

**2. 状态 API 通吗（唯一可靠的就绪信号）**

```sh
docker exec of-nexus curl -sS -o /dev/null -w '%{http_code}\n' \
  http://localhost:8081/service/rest/v1/status
```

期望 `200`。**注意这个端点 body 是空的**，只断言状态码 —— 空 body 会被 `curl -f`
误当成失败。

**3. 走网关通吗**

```sh
curl -sS -k -o /dev/null -w '%{http_code}\n' \
  --resolve nexus.<domain>:443:127.0.0.1 https://nexus.<domain>/
```

| 状态码 | 含义 |
|---|---|
| `200` | 正常 |
| `502` | 上游没起（回到第 2 步）→ 说明 **job 还没跑过**，这是 `make deploy` 之后的**预期状态** |
| `404` | Caddy 没这个站点，查 `config/routes.yaml` |
| `000` | 宿主的 `/etc/hosts` 缺这条（见 [待办](../待办.md)），用 `--resolve` 绕过 |

**4. 为什么起不来**

```sh
docker logs --tail=100 of-nexus | grep -iE 'error|exception|failed'
```

| 日志 | 原因 |
|---|---|
| `Directory /nexus-data is not writable` | 卷权限不对（宿主 umask 太严时会出现） |
| `Address already in use` | 端口冲突，通常是有另一个 nexus 在跑 |
| `OutOfMemoryError` | 容器内存不够，nexus 默认要 2G 以上 |
| 容器根本不存在 | job 没跑过，或跑了但失败 —— 看 job 控制台 |

**5. 磁盘满了吗**

```sh
docker system df
du -sh /var/lib/docker/volumes/*nexus_data*
```

nexus 吃磁盘很快（缓存 + 制品），满了会表现为「启动卡住、没有报错」。

## 常用命令

```sh
# 重启（不是 docker compose restart）
docker restart of-nexus

# 看卷占用
docker exec of-nexus du -sh /nexus-data

# 状态 API（不带网关，最直接）
docker exec of-nexus curl -sS -o /dev/null -w '%{http_code}\n' \
  http://localhost:8081/service/rest/v1/status

# 重新部署（幂等，可随时跑）
# → Jenkins job nexus-deploy

# 备份（会先停服）
make backup
```

## 已知边界

- 没有配 `auth: true`：Nexus 自己的账号体系没接 LDAP，谁都能打开界面。M1 再接
- 备份只含 `orgflow-devops_nexus_data`，不含镜像本身的配置（那是镜像的一部分，可重建）
- **job 只做「建容器 + 改密 + 删初始密码」**，不建仓库、不建角色。要加仓库得手工或用 REST

## 使用指南

```bash
USE_GHCR=1 make deploy                  # 先建 orgflow 网络
make jobs                               # 首次或 job 定义变了才需要
# 触发 Jenkins job nexus-deploy（UI 或 job/nexus-deploy/buildWithParameters）
docker exec of-nexus curl -sS -o /dev/null -w '%{http_code}\n' \
  http://localhost:8081/service/rest/v1/status
make backup                             # 备份 nexus_data
```

状态 API 返回 `200` 才算就绪（**body 为空，只断言状态码**）；`make deploy` 之后网关 `502`
是 job 还没跑的预期状态。

## 注意事项

- **不在 `docker-compose.yml` 里**：`docker compose ps` / `logs` 看不到它不是故障；用 `docker ps` / `docker logs` / `docker restart`（#46 起由 job 创建）。
- 卷名必须写全 `orgflow-devops_nexus_data`；写成 `nexus_data` 会落到匿名卷，表现为「数据看起来没了」。动手前 `docker volume ls | grep nexus_data` 记全名。
- 改密 API 要 `Content-Type: text/plain`、body 就是新密码本身，**写 JSON 会 415**；job 改密后删 `/nexus-data/admin.password`。
- `docker run` 没有 healthcheck，`Up N minutes` 属正常；状态 API 空 body 会被 `curl -f` 误判为失败。
- Nexus **CE 支持 LDAP，Pro-only 的是 SAML SSO**（`M0-增量需求总表.md` §1 第 1 条、§3 A5）；别把 SAML 写进需求或文档。
- 备份要求**数据库与 blob store 尽量同一时刻**；H2 部署有内置 `Admin - Backup H2 Database` 任务（`M0-增量需求总表.md` §1 第 7 条），不要只备其一。

## 设置

| 真源 | 路径 |
|---|---|
| 创建 / 改密 job 定义 | `config/job_definitions/nexus/nexus-deploy.yaml` |
| 等价脚本 | `scripts/nexus-deploy.sh` |
| 管理员账号 / 口令 | `.env` 的 `NEXUS_ADMIN_ID` / `NEXUS_ADMIN_PASSWORD`（值不入库、不写文档） |
| 全部状态 | `orgflow-devops_nexus_data` 卷 → `/nexus-data` |
| 其余配置 | 卷内配置文件或 UI `Admin → System` |

## 备份

**只保 `orgflow-devops_nexus_data`**（`make backup` / `backup-service` Job，备份前停服）。
注意数据库与 blob store 的同刻一致性（H2 内置备份任务，见上）；镜像本身与仓库定义可重建，
不含在卷备份里。恢复演练的验证点是「仓库列表与基线一致 + 抽查制品可下载」，
完整步骤见 [备份与恢复](../备份与恢复.md)。
