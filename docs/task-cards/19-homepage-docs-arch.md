# [19] Homepage 面板 + 每服务文档 + 网络架构图

- **Issue**：#19
- **PR**：（待填）
- **分支**：`feat/19-homepage-docs-arch`
- **类型**：正常派单（本卡同时是 #17「用某张卡实际派一次单」的验证样本）
- **依赖**：#16（`18_public.bats` 的包数断言要一起改）、#18（域名路由与固定 IP）
- **token 预算**：约 20 万 token

## 目标

三件事，都围绕「出了问题能自己查」：

1. **统一入口**：`https://home.<domain>` 一屏看到 5 张服务卡，点进去直达
2. **每服务一份文档**：`docs/services/<svc>.md` × 10，统一六段，排查段是能直接复制粘贴的命令
3. **一张能排障的架构图**：mermaid 拓扑 + 固定 IP 表 + 分层排查决策树 + 局域网访问说明

## 背景与取证

**这条最容易漏**：新增一个服务不是「往 compose 里加一段」就完了。本仓库有四处**写死服务数量**的断言，
加 `homepage` 会让它们全红。开工前先认清这四处：

| 位置 | 现在写死什么 | 加 homepage 后要变成 |
|---|---|---|
| `tests/bats/00_stack.bats:9-10` | `image:` 计数 `-eq 7`（含 sha256 计数也是 7） | `-eq 8` |
| `tests/bats/00_stack.bats:20` | `compose config --services` 行数 `-eq 9` | `-eq 10` |
| `tests/bats/00_stack.bats:21` | 服务名清单（9 个） | 加 `homepage` |
| `tests/bats/00_stack.bats:39-41` | `ipv4_address:` 计数 `-eq 9` × 3 处 | `-eq 10` |
| `tests/bats/18_public.bats` | 12 个 GHCR 包 | 13 个（加 `mirror-homepage`） |
| `tests/bats/00_stack.bats:7` | 用例标题写着 `nine services` | 改成 `ten services` |

**固定 IP 已被占用**（`172.31.0.0/24`）：

| IP | 服务 | IP | 服务 |
|---|---|---|---|
| `.2` | dnsmasq | `.21` | nexus |
| `.10` | caddy | `.22` | ldap |
| `.11` | router | `.23` | ldapadmin |
| `.20` | jenkins | `.24` | dex |
| | | `.25` | oauth2-proxy |

→ `homepage` 用 **`.26`**（`.1` 是网关，不要占）。

**homepage 的行为约束**（实测）：

| 事实 | 结论 |
|---|---|
| 未设 `HOMEPAGE_ALLOWED_HOSTS` 时非 localhost 访问被拒 | 必须显式设，且要由 `GATEWAY_DOMAIN` 驱动，不能写死 |
| 配置在 `/app/config/` 下按 `services.yaml` / `bookmarks.yaml` / `widgets.yaml` / `settings.yaml` 分文件 | 四个文件缺一个会起但页面空 |
| 容器内监听 `3000` | 反向代理指 `homepage:3000` |

## 范围

**改**

| 文件 | 改法 |
|---|---|
| `docker-compose.yml` | 新增 `homepage` 服务：`image:` 用 digest、`ipv4_address: 172.31.0.26`、挂 `./config/homepage:/app/config`、`HOMEPAGE_ALLOWED_HOSTS=home.${GATEWAY_DOMAIN}`、healthcheck |
| `config/routes.yaml` | 新增 `name: homepage` / `subdomain: home` / `upstream: homepage:3000` |
| `tests/images.lock` | 加 `homepage` 行（`gethomepage/homepage` 的 ref + digest） |
| `docker-compose.ghcr.yml` | 加 `homepage` 覆盖到 `mirror-homepage` |
| `.github/workflows/mirror.yml` | matrix 加一项：`src: docker.io/gethomepage/homepage:<tag>` / `dst: mirror-homepage` |
| `tests/bats/00_stack.bats` | 上表六处计数与清单，用例标题 `nine` → `ten` |
| `tests/bats/18_public.bats` | 包数 12 → 13，清单加 `mirror-homepage:<tag>` |
| `README.md` | 加主页入口与文档索引 |
| `docs/M0-最小核心.md` | 服务表加 `homepage` 一行 |

**新增**

| 文件 | 内容 |
|---|---|
| `config/homepage/settings.yaml` | 标题、主题、语言 |
| `config/homepage/services.yaml` | 5 张卡：jenkins / nexus / ldapadmin / dex / homepage。每张写内网域名 + 固定 IP |
| `config/homepage/bookmarks.yaml` | 外部参考链接（Caddy / Dex / Jenkins 官方文档） |
| `config/homepage/widgets.yaml` | 资源与信息组件；**不接任何需要凭据的 widget** |
| `docs/services/jenkins.md` 等 10 份 | 统一六段，见下 |
| `docs/network/arch.md` | mermaid 拓扑 + IP 表 + 排查决策树 + 局域网访问 |

**服务文档统一六段**（十份都必须齐）

1. 用途与端口
2. 入口与依赖（域名、上游、依赖谁、被谁依赖）
3. 部署与配置（改哪个文件、改完怎么生效）
4. 关键环境变量（变量名 + 作用 + 默认值；**不写真实值**）
5. 排查步骤（分层命令，至少 3 条可直接复制）
6. 常用命令

十份：`jenkins` `nexus` `ldap` `ldapadmin` `dex` `oauth2-proxy` `caddy` `router` `dnsmasq` `homepage`

## 验收

**结构与数量**

- [ ] `ls docs/services/*.md | wc -l` → `10`
- [ ] 每份文档都含六段标题：`for f in docs/services/*.md; do grep -c '^## ' "$f"; done` → 每份 ≥ `6`
- [ ] 每份「排查步骤」段至少 3 条命令：`awk '/^## 排查步骤/,/^## 常用命令/' docs/services/*.md | grep -c '^\s*\`\`\`\|^    '` → 逐份 ≥ `3`
- [ ] `grep -rn '大概\|可能\|应该是' docs/services/ docs/network/` → **无输出**

**主页可达**

- [ ] `make render` 后 `grep -c 'home\.' out/Caddyfile` → `1`
- [ ] `gw_curl home / -o /dev/null -w '%{http_code}'` → `200`（在 bats 里加一条 `21_homepage.bats`，或并入 `14_caddy.bats`）
- [ ] 页面 HTML 里含 5 个服务名：`gw_curl home / | grep -c 'jenkins\|nexus\|ldapadmin\|dex'` → ≥ `4`

**IP 表与真实值一致（脚本比对）**

- [ ] `docs/network/arch.md` 的 IP 表逐行对上真实容器：
      `for s in dnsmasq caddy router jenkins nexus ldap ldapadmin dex oauth2-proxy homepage; do docker compose exec -T $s ip -4 addr show scope global | grep -o '172\.31\.0\.[0-9]*'; done`
      输出必须与文档表格逐行相同
- [ ] 反证：把文档里某个 IP 改成 `.99` → 上面这条比对**必须报错**（脚本要能 diff 出不一致，不能只是人眼看）

**mermaid 渲染**

- [ ] `docs/network/arch.md` 在 GitHub 上 mermaid 正常渲染（贴截图或渲染后的 SVG 取证）

**回归**

- [ ] `make test` → 退出码 `0`
- [ ] `make test-bats` → **全绿**（含改过计数的 `00_stack` 与 `18_public`）
- [ ] `docker compose -f docker-compose.yml -f docker-compose.ghcr.yml config -q` → 退出码 `0`

## 禁止事项

- 不得在 `config/homepage/` 里放任何凭据：widget 一律不接需要 token 的接口
- 不得在文档里写 `.env` 的真实密码：只写变量名、作用、默认值
- 不得把 `HOMEPAGE_ALLOWED_HOSTS` 写死成某个域名：必须由 `GATEWAY_DOMAIN` 驱动
- 不得为了过 `00_stack.bats` 而删掉计数断言：断言是「新服务必须被登记」的守门人
- 不得占用 `.1` / `.2` / `.10` / `.11` / `.20`–`.25` 已有 IP
- 不得写「大概」「可能」这类无法验证的描述
- 不得自行合并 PR

## 依赖与前置

- [ ] `docker compose config -q` → 退出码 `0`
- [ ] `make render` → 退出码 `0`
- [ ] 能拉到 `gethomepage/homepage`（Docker Hub 不可达时先经 `mirror.yml` 镜像）
- [ ] `tests/images.lock` 里已有 `ubuntu` 之外的 homepage 条目（需先 `make images-lock` 或手工填 digest）

## 交付物

- [ ] 分支 `feat/19-homepage-docs-arch`
- [ ] PR 正文含：做了什么 / 六处计数断言的改动说明 / 验收实测表 / mermaid 渲染取证 / 未验证项
- [ ] 验收输出原样贴（命令 + 真实输出）

## 交付后的记录

完成后由派单方补充：

- PR：#
- 结果：
- 与本卡的偏离：
