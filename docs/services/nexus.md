# nexus

制品仓库。存 Maven / npm / docker 等构建产物。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-nexus` |
| 固定 IP | `172.31.0.21` |
| 端口 | `8081`（容器内，不发布到宿主） |
| 镜像 | `sonatype/nexus3:3.92.2@sha256:a32ae23e…` |
| 卷 | `nexus_data` → `/nexus-data` |

## 入口与依赖

- **入口**：`https://nexus.org-devops.com`，**不需要登录**（`routes.yaml` 里没有 `auth: true`）
- **依赖谁**：`dnsmasq`
- **被谁依赖**：无。Jenkins 的 Job 可以把产物推到它，但不是启动依赖

首次启动要 **2 分钟以上**（要初始化 OrientDB 和内置仓库），健康检查的 `start_period` 设的就是 `120s`。
这段时间里 `starting` 是正常的，别急着判故障。

## 部署与配置

```bash
docker compose up -d nexus
```

| 位置 | 作用 |
|---|---|
| `nexus_data` 卷 | 全部状态：仓库、用户、配置。**备份只保这个卷** |
| `/nexus-data/admin.password` | 首次启动生成的 admin 初始密码 |

初始密码只在第一次启动时生成一次，读它：

```bash
docker compose exec -T nexus cat /nexus-data/admin.password
```

**别把它 echo 到终端历史里**——真要贴给别人，先改密码。

## 关键环境变量

compose 里没有给它注入业务变量，全是镜像默认。需要调的都在 `nexus_data` 里的配置文件，
或者界面上的 `Admin → System`。

## 排查步骤

**1. 容器健康吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-nexus
docker compose ps nexus
```

`starting` 持续超过 5 分钟才算异常。

**2. 状态 API 通吗（最可靠的就绪信号）**

```bash
docker compose exec -T nexus curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8081/service/rest/v1/status
```

期望 `200`。**注意这个端点 body 是空的**，只断言状态码——用 `curl -f` 之外的判断方式，
否则空 body 会被误当成失败。

**3. 走网关通吗**

```bash
curl -sS -k -o /dev/null -w '%{http_code}\n' --resolve nexus.org-devops.com:443:127.0.0.1 https://nexus.org-devops.com:443/
```

期望 `200`。`502` 说明上游没起（回到第 2 步）；`404` 说明 Caddy 没这个站点。

**4. 为什么起不来**

```bash
docker compose logs --tail=100 nexus | grep -iE 'error|exception|failed'
```

常见原因：

| 日志 | 原因 |
|---|---|
| `Directory /nexus-data is not writable` | 卷权限不对（宿主 umask 太严时会出现） |
| `Address already in use` | 端口冲突，通常是有另一个 nexus 在跑 |
| `OutOfMemoryError` | 容器内存不够，nexus 默认要 2G 以上 |

**5. 磁盘满了吗**

```bash
docker system df
du -sh /var/lib/docker/volumes/*nexus_data*
```

nexus 吃磁盘很快（缓存 + 制品），满了会表现为「启动卡住、没有报错」。

## 常用命令

```bash
# 重启
docker compose restart nexus

# 看卷占用
docker compose exec -T nexus du -sh /nexus-data

# 状态 API（不带网关，最直接）
docker compose exec -T nexus curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8081/service/rest/v1/status

# 备份（会先停服）
make backup
```

## 已知边界

- 没有配 `auth: true`：Nexus 自己的账号体系没接 LDAP，谁都能打开界面。M1 再接
- 备份只含 `nexus_data`，不含镜像本身的配置（那是镜像的一部分，可重建）
