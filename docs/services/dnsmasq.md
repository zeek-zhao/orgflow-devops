# dnsmasq

内部 DNS。把 `*.org-devops.com` 整段解析到 Caddy 的固定 IP，让容器之间用域名互访而不是靠服务名。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-dnsmasq` |
| 固定 IP | `172.31.0.2` |
| 监听端口 | `53/udp`、`53/tcp`（只绑 `172.31.0.2`） |
| 镜像 | 自建，基于 `ubuntu:24.04@sha256:fe8156…`，Dockerfile 在 `services/dnsmasq/` |

**只绑 `172.31.0.2` 而不是 `0.0.0.0`**：容器内 `127.0.0.11:53` 是 Docker 自己的内嵌 DNS，
绑 `0.0.0.0` 会撞上，表现是 dnsmasq 起不来或间歇性不响应。

## 入口与依赖

- **入口**：不对外暴露。局域网机器用宿主 `hosts` 片段（`make hosts` 生成），不用它
- **上游**：未匹配的查询转发给 `127.0.0.11`（Docker 内嵌 DNS），所以服务名仍能解析
- **被谁依赖**：所有业务容器都把 `dns: 172.31.0.2` 指过来，并 `depends_on` 它的 healthy
- **依赖谁**：无

dnsmasq 挂掉的表现不是「DNS 报错」，而是**所有容器一起变慢或起不来**——它们启动时要解析域名。

## 部署与配置

改动入口只有环境变量，没有配置文件需要手改：

| 变量 | 作用 |
|---|---|
| `GATEWAY_DOMAIN` | 域名后缀，默认 `org-devops.com` |
| `GATEWAY_IP` | 整段域名解析到哪个 IP，默认 `172.31.0.10`（Caddy） |
| `DNSMASQ_LISTEN_IP` | dnsmasq 自己绑哪个地址，默认 `172.31.0.2` |

改完重启：

```bash
docker compose up -d dnsmasq
```

**新增服务不需要改 dnsmasq**：它按域名后缀整段匹配，加一个 `foo.org-devops.com` 自动生效。

## 关键环境变量

见上表。三个都有默认值，正常情况下 `.env` 里只需要 `GATEWAY_DOMAIN`。

## 排查步骤

按顺序执行，前一条通过再走下一条。

**1. 容器活着吗**

```bash
docker compose ps dnsmasq
docker inspect -f '{{.State.Health.Status}}' of-dnsmasq
```

期望 `healthy`。`starting` 卡住超过 30 秒说明它自己解析不了测试域名。

**2. 它自己解析得对吗**

```bash
docker compose exec -T dnsmasq dig +short jenkins.org-devops.com @172.31.0.2
```

期望 `172.31.0.10`。返回空说明配置没生效；返回别的 IP 说明 `GATEWAY_IP` 不对。

**3. 整段域名都覆盖了吗**

```bash
docker compose exec -T dnsmasq dig +short home.org-devops.com @172.31.0.2
docker compose exec -T dnsmasq dig +short anything.org-devops.com @172.31.0.2
```

两条的期望输出都是 `172.31.0.10`。如果第一条有、第二条没有，说明配的是单条记录而不是域名段。

**4. 从别的容器问得到吗**

```bash
docker compose exec -T router dig +short jenkins.org-devops.com
```

期望 `172.31.0.10`。这一步和上一步的区别是：上一步问的是 dnsmasq 自己，这一步问的是**别的容器**
通过 `dns:` 指向它。这步失败而第 2 步成功，说明某个服务的 `dns:` 配置漏了。

**5. 服务名还能解析吗（转发是否正常）**

```bash
docker compose exec -T router getent hosts dex
```

期望能拿到 dex 的地址。失败说明 dnsmasq 的上游转发断了——它把 `127.0.0.11` 弄丢了，
结果是「域名能解析、服务名不能解析」，jenkins 访问 dex 会失败。

**6. 日志里看实际查询**

```bash
docker compose logs --tail=50 dnsmasq | grep -E 'query|config|forwarded'
```

`config <域名> is <IP>` 是命中域名段；`forwarded ... to 127.0.0.11` 是走上游转发。
只有 forwarded 没有 config，说明域名段没匹配上。

## 常用命令

```bash
# 重启
docker compose restart dnsmasq

# 从宿主直接查（宿主没配 hosts 时用这个验证 DNS 本身）
dig +short jenkins.org-devops.com @172.31.0.2

# 生成宿主/局域网用的 hosts 片段
make hosts
make hosts IP=192.168.1.50

# 看它到底绑在哪个地址上
docker compose exec -T dnsmasq ss -lunp | grep :53
```

## 使用指南

```bash
docker compose up -d dnsmasq                        # 改完 .env 后重启
docker compose exec -T dnsmasq dig +short jenkins.org-devops.com @172.31.0.2
docker compose exec -T router dig +short jenkins.org-devops.com    # 从别的容器验证
make hosts                                          # 生成宿主/局域网 hosts 片段
```

两条 `dig` 都应返回 `172.31.0.10`（Caddy）。新增服务不用改 dnsmasq，整段后缀自动匹配。

## 注意事项

- **只绑 `172.31.0.2`，不能绑 `0.0.0.0`**：容器内 `127.0.0.11:53` 是 Docker 内嵌 DNS，绑全地址会冲突，表现为起不来或间歇不响应。
- 挂掉的表现不是「DNS 报错」，而是**所有容器一起变慢或起不来**（启动时要解析域名），排查容易被带到业务服务上。
- `make deploy SERVICE=xxx` **不重建容器**：compose 认为无变化就跳过，改了 bind mount 配置要 `docker compose --env-file .env restart <svc>`。
- 服务名解析走上游转发到 `127.0.0.11`；日志里只剩 `forwarded` 没有 `config <域名> is <IP>`，说明域名段没匹配上（排查段第 6 步）。

## 设置

| 真源 | 路径 / 变量 |
|---|---|
| 容器定义 | `docker-compose.yml` 的 `dnsmasq` 段、`services/dnsmasq/` Dockerfile |
| 域名后缀 | `.env` 的 `GATEWAY_DOMAIN` |
| 整段解析目标 | `.env` 的 `GATEWAY_IP`（默认 `172.31.0.10`） |
| 监听地址 | `.env` 的 `DNSMASQ_LISTEN_IP`（默认 `172.31.0.2`） |

没有需要手改的配置文件；三个变量都有默认值。

## 备份

dnsmasq **无状态、无数据卷**：配置在 `.env` 与 `docker-compose.yml`（Git），容器可随时重建，
不在 `make backup` 范围内。域名解析规则与固定 IP 表的约定见
[备份与恢复](../备份与恢复.md)「范围与前提」；本服务无单独恢复演练项。
