# homepage

统一入口。一屏看到所有服务，点进去直达。就是 `https://home.org-devops.com` 那一页。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-homepage` |
| 固定 IP | `172.31.0.26` |
| 端口 | `3000`（容器内，不发布到宿主） |
| 镜像 | `gethomepage/homepage:v2.7.0@sha256:19c5c091…` |
| 配置 | `./config/homepage` → `/app/config`（**可写**） |

配置目录**不能挂 `:ro`**：homepage 默认把运行日志写到 `config/logs/` 下，只读会起不来。

## 入口与依赖

- **入口**：`https://home.org-devops.com`，**不需要登录**
- **依赖谁**：`dnsmasq`
- **被谁依赖**：无

**为什么不做鉴权**：它是入口页，加登录就变成「先登录才能看到去哪登录」。所以卡片里只放
公开可达的服务，任何需要 token 的 widget 都不接——首页是公开的，往里塞凭据等于把凭据摆在门口。

## 部署与配置

```bash
make render                     # 让 routes.yaml 里新增的 home 站点生效
docker compose up -d homepage
```

四个配置文件，缺一个会起但页面空：

| 文件 | 作用 |
|---|---|
| `config/homepage/settings.yaml` | 标题、语言、主题、布局 |
| `config/homepage/services.yaml` | 服务卡片（5 张） |
| `config/homepage/bookmarks.yaml` | 外部文档链接 |
| `config/homepage/widgets.yaml` | 资源 / 时间 / 搜索 |

改完配置**不用重启**，homepage 会自己重载。

## 关键环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `HOMEPAGE_ALLOWED_HOSTS` | 允许的 Host 头，**必填** | `home.<GATEWAY_DOMAIN>` |
| `HOMEPAGE_VAR_GATEWAY_DOMAIN` | 给 yaml 里的 `{{HOMEPAGE_VAR_GATEWAY_DOMAIN}}` 用 | `GATEWAY_DOMAIN` |
| `PUID` / `PGID` | 运行身份 | `1000` |

**`HOMEPAGE_ALLOWED_HOSTS` 必须由 `GATEWAY_DOMAIN` 驱动。** homepage 会校验 Host 头，
写死某个域名后换域名访问会直接返回 `400`，页面只有一句 `host not allowed`——
看不出是配置问题还是路由问题。

卡片里的链接也走变量（`https://jenkins.{{HOMEPAGE_VAR_GATEWAY_DOMAIN}}`），
换域名只改 `.env`，不用回来改 yaml。

## 排查步骤

**1. 容器健康吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-homepage
docker compose ps homepage
```

健康检查用 `node` 自检（镜像里不一定有 `wget`/`curl`，但一定有 node）。

**2. 它自己活着吗**

```bash
docker compose exec -T homepage node -e "require('http').get('http://127.0.0.1:3000/',r=>{console.log(r.statusCode);process.exit(0)}).on('error',e=>{console.log(e.message);process.exit(1)})"
```

期望打印 `200`。

**3. 走网关能打开吗**

```bash
curl -sS -k -o /dev/null -w '%{http_code}\n' --resolve home.org-devops.com:443:127.0.0.1 https://home.org-devops.com:443/
```

返回 `400` → `HOMEPAGE_ALLOWED_HOSTS` 没包含这个域名。返回 `404` → Caddy 没这个站点，
`make render` 跑过没有。

**4. 卡片在不在**

```bash
curl -sS -k --resolve home.org-devops.com:443:127.0.0.1 https://home.org-devops.com:443/ | grep -cE 'jenkins|nexus|ldapadmin'
```

期望 ≥ `3`。页面出来但一张卡都没有 → `services.yaml` 的 YAML 格式有问题（缩进错一层就整段失效），
看日志：

```bash
docker compose logs --tail=40 homepage | grep -iE 'error|invalid|yaml'
```

**5. 图标全裂**

图标用的是 `mdi-*`（homepage 自带 Material Design Icons，不依赖外网）。如果换成
`jenkins.png` 这类 dashboard-icons 名字，断网时整张卡片会变裂图——改回 `mdi-*`。

**6. 配置改了没生效**

```bash
docker compose exec -T homepage ls -l --time-style=full-iso /app/config/
docker compose logs --tail=20 homepage
```

确认挂载的是宿主目录而不是镜像内副本：

```bash
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' of-homepage
```

## 常用命令

```bash
# 重启
docker compose restart homepage

# 改完 routes.yaml 后
make render && docker compose restart caddy

# 检查四个配置文件都在
ls config/homepage/

# 页面里出现了哪些服务名
curl -sS -k --resolve home.org-devops.com:443:127.0.0.1 https://home.org-devops.com:443/ \
  | grep -oE 'Jenkins|Nexus|LDAP Admin|Dex|Homepage' | sort -u
```

## 已知边界

- 首页**不做鉴权**，所以不放任何带凭据的 widget
- `resources` widget 读的是 homepage 容器自己的 cgroup，不是宿主的——数字仅供参考。
  要看宿主真实资源用 `docker stats`
- 卡片里的 IP 是手写的。新增服务时记得同时更新 `services.yaml` 和 `docs/network/arch.md`，
  两处不一致时 `docs/network/arch.md` 的比对脚本会报错
