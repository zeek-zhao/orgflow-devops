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
| `config/homepage/services.yaml` | 服务卡片（6 张，含状态探测字段） |
| `config/homepage/bookmarks.yaml` | 官方文档 + 本地文档直链 |
| `config/homepage/widgets.yaml` | 资源 / 时间 / 天气 / 搜索 |

改完配置**不用重启**，homepage 会自己重载。

## 关键环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `HOMEPAGE_ALLOWED_HOSTS` | 允许的 Host 头，**必填**；逗号分隔，带端口与不带端口两种写法都要列 | `home.<GATEWAY_DOMAIN>`, `home.<GATEWAY_DOMAIN>:<GATEWAY_HTTPS_PORT>` |
| `HOMEPAGE_VAR_GATEWAY_DOMAIN` | 给 yaml 里的 `{{HOMEPAGE_VAR_GATEWAY_DOMAIN}}` 用 | `GATEWAY_DOMAIN` |
| `PUID` / `PGID` | 运行身份 | `1000` |

**`HOMEPAGE_ALLOWED_HOSTS` 必须由 `GATEWAY_DOMAIN` 驱动。** homepage 会校验 Host 头，
写死某个域名后换域名访问会直接返回 `400`，页面只有一句 `host not allowed`——
看不出是配置问题还是路由问题。

**端口也要列进去。** 这个校验是拿 Host 头做精确匹配，而 Host 头里带不带端口取决于访问者敲的 URL：
`https://home.example.com/` 发的是 `home.example.com`，`https://home.example.com:8443/` 发的是
`home.example.com:8443`。只列不带端口的那条，非 443 端口访问（CI 用 8443、局域网自测常用 8443）
必然 400——而这个 400 和「服务根本没起来」在浏览器里长得一模一样。

卡片里的链接也走变量（`https://jenkins.{{HOMEPAGE_VAR_GATEWAY_DOMAIN}}`），
换域名只改 `.env`，不用回来改 yaml。

## 排查步骤

**1. 容器健康吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-homepage
docker compose ps homepage
```

健康检查用 `node` 自检（镜像里不一定有 `wget`/`curl`，但一定有 node），判据是 `<500` 而非 `==200`：
探针从 `127.0.0.1` 发，Host 不在白名单里，**正常就返回 400**。那 400 恰好证明 HTTP 服务活着。

**2. 它自己活着吗**

```bash
docker compose exec -T homepage node -e "require('http').get('http://127.0.0.1:3000/',r=>{console.log(r.statusCode);process.exit(0)}).on('error',e=>{console.log(e.message);process.exit(1)})"
```

期望打印 `400`（Host 是 `127.0.0.1`，不在白名单）。打印 `200` 说明白名单被放宽了；
连不上或超时才是真的没起来。

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
  | grep -oE 'Jenkins|Nexus|LDAP Admin|Dex|Homepage|认证网关' | sort -u
```

## 已知边界

- 首页**不做鉴权**，所以不放任何带凭据的 widget
- `resources` widget 读的是 homepage 容器自己的 cgroup，不是宿主的——数字仅供参考。
  要看宿主真实资源用 `docker stats`
- 卡片里的 IP 是手写的。新增服务时记得同时更新 `services.yaml` 和 `docs/network/arch.md`，
  两处不一致时 `docs/network/arch.md` 的比对脚本会报错

---

## 首页这块板子（#94 / REQ-M0-C1）

首页要一眼看到三样东西：**每个服务活没活**、**现在几点**、**天气**；并且每份服务文档
都能从首页点开、还写清「怎么用」。

- **存活状态**：`services.yaml` 每张卡带 `siteMonitor`（HTTP 探测）与 `ping`（服务级
  ping）两个字段，前端据此画状态点。探测地址是 compose 内网服务名 + 端口，不经网关、
  不要 token。
- **时间**：`widgets.yaml` 的 `datetime`（纯前端）。
- **天气**：`widgets.yaml` 的 `customapi` 直连 Open-Meteo，URL 在配置里可核对，无 apikey。
- **文档直链**：`bookmarks.yaml` 的「本地文档」分组，11 份服务文档逐条列出，名字里带用途。

### 容器内 widget 实测（v2.7.0，只读）

总表 §1 把 `siteMonitor` / `openmeteo` 标为二手资料，按卡要求在 213 容器内只读核了一遍。
213 跑的是 `of-homepage` / `ghcr.io/zeek-zhao/orgflow-devops/mirror-homepage:v2.7.0`：

```bash
docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' | grep -i home
docker exec of-homepage sh -c "grep -m1 version /app/package.json; ls /app/src/components/widgets/"
docker exec of-homepage sh -c "ls /app/.next/server/pages/api/; ls /app/.next/server/pages/api/widgets/"
```

真实输出（节选）：

```
of-homepage|ghcr.io/zeek-zhao/orgflow-devops/mirror-homepage:v2.7.0|Up 3 days (healthy)
  "version": "2.7.0",
customapi  datetime  glances  greeting  kubernetes  logo  longhorn
openmeteo  openweathermap  resources  stocks  unifi_console  weather
siteMonitor.js  ping.js  bookmarks.js  ...  widgets/openmeteo.js  widgets/customapi.js
```

| 二手结论 | 实测 | 采用 |
|---|---|---|
| `siteMonitor` 是服务卡 `ping` 字段 | `/api/siteMonitor.js` 读服务卡 `siteMonitor` 字段做 HTTP HEAD（`>403` 回退 GET），返回状态码 + 延迟；`/api/ping.js` 读 `ping` 字段走 **ICMP**，两者是不同字段 | 每卡同时写 `siteMonitor`（HTTP，主）与 `ping`（服务级状态） |
| `widgets.yaml` 有 `siteMonitor` widget | 组件目录里**没有** `siteMonitor`；它只以 API + 服务卡字段形式存在 | 不在 `widgets.yaml` 写 `- siteMonitor:`（不存在的类型） |
| Homepage 有 `openmeteo` provider | 组件与 `/api/widgets/openmeteo.js` 都在，但后端硬编码 `...&current_weather=true`（旧参数）、URL 不可配置，前端读 `data.current_weather.temperature` | 不用，见下 |
| Homepage 有 `customapi` widget | 组件 + `/api/widgets/customapi.js` 都在；读 `url` 字段，缺失报 `Missing Custom API URL`；`url/headers/key/apiKey` 等敏感字段不下发前端 | **采用** |

### 天气为什么走 customapi 而不是 openmeteo

Open-Meteo 官方：非商业 + <10,000 次/日 下 `api.open-meteo.com` 不需要 `apikey`，
当前天气走 `/v1/forecast?latitude=..&longitude=..&current=temperature_2m,...`
（总表 §1 第 10 条，官方逐字）。镜像虽自带 `openmeteo` widget，但 v2.7.0 的实现用的是
旧版 `current_weather=true`，且 URL 硬编码在镜像里、`widgets.yaml` 改不动，既对不上本卡
指定的 URL 契约，也没法「贴配置片段」证明 URL 不含 key。因此降级为
**`customapi` + Open-Meteo**：URL 明写在 `widgets.yaml`，
`scripts/test_homepage_config.py` 逐字符断言不含 `apikey` / `key=` / `token`。
不硬写任何不存在的 widget 类型，也不接 `openweathermap`（要 key）。

配置片段（`config/homepage/widgets.yaml`，即「天气请求 URL 不含 apikey」的验收证据）：

```yaml
- customapi:
    label: 天气 · Open-Meteo
    url: "https://api.open-meteo.com/v1/forecast?latitude=31.2304&longitude=121.4737&current=temperature_2m,relative_humidity_2m,weather_code&timezone=auto"
    refreshInterval: 300000
    icon: mdi-weather-partly-cloudy
    mappings:
      - field: current.temperature_2m
        label: 气温
        format: text
      - field: current.relative_humidity_2m
        label: 湿度
        format: text
```

URL 里没有 `apikey` / `key` / `token`，也没有 `customer-` 前缀（商业版才要）。
经纬度是固定示例坐标，换城市只改 `latitude` / `longitude`。

### 活性检测：siteMonitor 与 ping 不是一回事

实测两个 API 分别读两个不同字段：`/api/siteMonitor` 拿 `siteMonitor` 的值发 HTTP
`HEAD`（状态码 >403 时回退 `GET`），返回 `{status, latency}`；`/api/ping` 拿 `ping`
的值，`new URL(...).hostname` 后交给 `ping` npm 包做 **ICMP** probe。所以「服务级 ping」
在本版本是 ICMP，不是 HTTP；真正符合「免凭据 HTTP 探测」的是 `siteMonitor`。
两张都留着：HTTP 结果为主，ICMP 作补充，两个字段都不需要任何凭据。

### 文档直链怎么用

「本地文档」分组里每条书签的名字 `·` 后面就是用途，点开即到仓库 main 上的文档真源。
按场景找：

| 想干什么 | 点开 |
|---|---|
| 建 / 改 CI 流水线、看构建为什么挂 | Jenkins · 建流水线与排障 |
| 上传下载制品、配仓库 | Nexus · 传包与制品仓库 |
| 加人、改部门、改组 | LDAP Admin · 改用户与部门 |
| 目录服务本身连不上 | LDAP · 目录服务排查 |
| 登录跳不过去、OIDC 报错 | Dex · OIDC 登录排障 与 OAuth2 Proxy · 网关与登录 |
| 加站点、证书、路由不生效 | Caddy · 路由与证书 与 Router · 渲染与热加载 |
| 容器内域名解析不到 | dnsmasq · 容器内 DNS |
| 构建节点掉线 | Jenkins Agent · 构建节点 |
| 首页自己不对劲 | Homepage · 就是这一页 |
| 按 IP / 分层定位 | 网络架构 · 分层排查 |

首页公开的，文档链接只指向公开可读的仓库文档；需要凭据的后台操作（Jenkins API
token、Nexus 口令）一律不进首页，按各文档里的命令现查。

### 静态核对与反证

`scripts/test_homepage_config.py` 纳入 `make test`，纯标准库（CI 裸 python3 没有
PyYAML）。检查项：

- 每张服务卡都有 `siteMonitor` + `ping` 探测字段，`description` 写清「怎么用」并指向
  `docs/services/`，`grep -c docs/ services.yaml` ≥ 服务卡数
- 天气 URL 指向 `api.open-meteo.com/v1/forecast`、含 `current=temperature_2m`、
  不含任何凭据参数；`widgets.yaml` 不出现凭据字段与要 key 的天气 widget；`datetime` 存在
- `bookmarks.yaml` 每个书签的值是**列表**且带 `href`（写成映射前端
  `new URL(e.href)` 会炸）；11 份 `docs/services/*.md` 每份都有可点直链

**反证（本轮禁止停止/重启任何容器，运行时反证改为配置层）**：

```bash
cp config/homepage/services.yaml /tmp/services.yaml.bak
grep -v 'siteMonitor: http://jenkins:8080/login' /tmp/services.yaml.bak > config/homepage/services.yaml
python3 scripts/test_homepage_config.py     # 自检必须红
cp /tmp/services.yaml.bak config/homepage/services.yaml
python3 scripts/test_homepage_config.py     # 恢复后复绿
```

删掉任一服务卡的探测字段 → `test_every_service_has_probe_fields` 红；恢复后复绿。
两次真实输出原样贴在下面。

### 未验证项

- **运行时状态翻转**：本轮禁止停止/重启任何容器，「停掉 of-nexus → 首页变 down →
  恢复变 up」未做，改用上面的静态反证代替；卡片验收里那一条保持未验证。
- **首页 HTTP 200 / 6 张卡实际渲染**：改动落在独立 worktree，未 `make deploy`、未重启
  homepage，运行中的 213 栈读的是主仓库的 `config/homepage`，页面效果本轮未验证。
- **`ping` 的 ICMP 实际结果**：`/api/ping` 走 ICMP，容器能力 / 网络策略下的真实通断未
  验证，以 `siteMonitor` 的 HTTP 结果为准。
- **天气实取**：未从容器内实际请求 `api.open-meteo.com`（213 出网策略未知），
  仅核对 URL 与组件契约。

#### 反证 A：删掉 Jenkins 卡的 `siteMonitor` 探测字段 → 自检红

```text
$ cp config/homepage/services.yaml .services.yaml.bak
$ grep -v "siteMonitor: http://jenkins:8080/login" .services.yaml.bak > config/homepage/services.yaml
$ python3 scripts/test_homepage_config.py
test_bookmark_values_are_lists (__main__.BookmarkTests) ... ok
test_every_service_doc_has_bookmark (__main__.BookmarkTests) ... ok
test_local_doc_bookmarks_explain_usage (__main__.BookmarkTests) ... ok
test_at_least_six_service_cards (__main__.ServiceCardTests) ... ok
test_docs_path_count_matches_cards (__main__.ServiceCardTests) ... ok
test_every_service_explains_usage (__main__.ServiceCardTests) ... ok
test_every_service_has_probe_fields (__main__.ServiceCardTests) ... FAIL
test_every_service_links_its_doc (__main__.ServiceCardTests) ... ok
test_datetime_widget_present (__main__.WidgetTests) ... ok
test_no_credential_fields (__main__.WidgetTests) ... ok
test_weather_url_has_no_apikey (__main__.WidgetTests) ... ok
test_weather_widget_is_customapi (__main__.WidgetTests) ... ok

======================================================================
FAIL: test_every_service_has_probe_fields (__main__.ServiceCardTests)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/tmp/wt-94/scripts/test_homepage_config.py", line 106, in test_every_service_has_probe_fields
    self.assertEqual(missing, [], "服务卡缺探测/状态字段（删掉就红）：\n  " + "\n  ".join(missing))
AssertionError: Lists differ: ['Jenkins 缺 siteMonitor'] != []

First list contains 1 additional elements.
First extra element 0:
'Jenkins 缺 siteMonitor'

- ['Jenkins 缺 siteMonitor']
+ [] : 服务卡缺探测/状态字段（删掉就红）：
  Jenkins 缺 siteMonitor

----------------------------------------------------------------------
Ran 12 tests in 0.001s

FAILED (failures=1)
RC_A=1
```

#### 反证 B：恢复配置 → 复绿

```text
$ cp .services.yaml.bak config/homepage/services.yaml
$ python3 scripts/test_homepage_config.py
test_bookmark_values_are_lists (__main__.BookmarkTests) ... ok
test_every_service_doc_has_bookmark (__main__.BookmarkTests) ... ok
test_local_doc_bookmarks_explain_usage (__main__.BookmarkTests) ... ok
test_at_least_six_service_cards (__main__.ServiceCardTests) ... ok
test_docs_path_count_matches_cards (__main__.ServiceCardTests) ... ok
test_every_service_explains_usage (__main__.ServiceCardTests) ... ok
test_every_service_has_probe_fields (__main__.ServiceCardTests) ... ok
test_every_service_links_its_doc (__main__.ServiceCardTests) ... ok
test_datetime_widget_present (__main__.WidgetTests) ... ok
test_no_credential_fields (__main__.WidgetTests) ... ok
test_weather_url_has_no_apikey (__main__.WidgetTests) ... ok
test_weather_widget_is_customapi (__main__.WidgetTests) ... ok

----------------------------------------------------------------------
Ran 12 tests in 0.001s

OK
RC_B=0
```
