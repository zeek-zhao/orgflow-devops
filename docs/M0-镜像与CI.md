# M0 镜像与 CI

## 三个工作流

| 工作流 | 职责 | 触发 |
|---|---|---|
| `images.yml` | Buildx matrix 构建 router、jjb、m0-test、dnsmasq、jenkins；非 PR 推 GHCR，每项输出 digest，汇总为 `digests.txt` artifact | main push / PR，限定 `tests/harness/**`、`services/router/**`、`services/dnsmasq/**`、`tools/jjb/**`、`tools/jenkins/**` 和工作流本身；也可手动触发 |
| `mirror.yml` | skopeo 搬运 lock 中 7 个服务镜像和 Ubuntu 基座，逐项记录源/目标 digest | 手动（`mode=amd64` 默认 / `all`）；每周一 03:00 **UTC** 定时，默认 amd64 |
| `test.yml` | `make test`，再 `ALLOW_PULL_DOCKER_HUB=1 make test-bats`；30 分钟超时，失败上传 `bats-failure-log` | main push、所有 PR、手动 |

CI 仅用 `secrets.GITHUB_TOKEN` 登录 GHCR，镜像工作流需要 `packages: write`，
源码权限是 `contents: read`。PR 只构建，不登录、不推送；PR summary 中的 digest
不是已发布镜像，不能用于部署。测试中 `pipefail` 保留 bats 的失败状态，
`/tmp/bats-run.log` 包含构建、健康闸门及 TAP 输出。

包名前缀固定为小写 `ghcr.io/zeek-zhao/orgflow-devops/`：
自建包是 `router`、`jjb`、`m0-test`、`dnsmasq`、`jenkins`，标签为 `sha-<7位>`、`24.04-v1`，
以及只在默认分支生成的 `latest`。分支手动构建会更新 `24.04-v1`，不会更新 `latest`；
部署始终以 `@sha256:...` 锁定，标签只是可读提示。

`jenkins` 是**自建而非搬运**：上游 `jenkins/jenkins` 不带任何插件，
pipeline job、`git`、`ssh-slaves`、`configuration-as-code` 全都没有，
所以改成 `FROM jenkins/jenkins:lts-jdk21` + `tools/jenkins/plugins.txt`。
它的底座在 Docker Hub 上、213 拉不到，**因此只能在 runner 上构建后推 GHCR**，
`tests/images.lock` 里不再有 jenkins 行，`docker-compose.yml` 里它也从 `image:` 变成 `build:`。

搬运包名扁平化为 `mirror-caddy`、`mirror-openldap`、
`mirror-phpldapadmin`、`mirror-dex`、`mirror-oauth2-proxy`、`mirror-nexus`、
`mirror-ubuntu`。搬运源使用 `tests/images.lock` 的 digest，避免可变上游 tag
移动导致 override 的 digest 在 GHCR 不存在；升级仍按测试文档更新 lock。

> ### ★ 新建的 GHCR 包默认是 private
>
> GHCR **不会**继承仓库的可见性。新包（比如首次出现的 `jenkins`）建出来就是 private，
> 匿名拉取会 401。而 213 的设计前提是「全部包 public、拉取不需要登录」，
> 于是症状变成「镜像拉不下来」，很容易误判成网络或凭据问题。
>
> 这个开关**改不了 API**：`PATCH /user/packages/container/<name>` 对仓库关联的包一律 404
> （即便令牌带 `write:packages`）。只能到
> `https://github.com/users/zeek-zhao/packages/container/orgflow-devops%2F<name>/settings`
> 手动把 Visibility 改成 Public，一次即可。
>
> 防线是 `tests/bats/18_public.bats`：它走完全匿名路径取 manifest，
> 谁把包改回 private 或漏了新包，PR 阶段就会红，而不是等到 213 上才发现。

## 首次发布、搬运、回写

1. push 并合入 main，等待 `images.yml` 绿色（路径过滤未命中时，在 main 手动运行）。
   可在 Summary / `digests.txt` 查看四个产物。分支构建不生成 `latest`，不能代替此步骤。
2. 手动执行 `mirror.yml`，**选择 `mode=all`**，等待七项完成。
   `--all --preserve-digests` 保留多架构索引与 manifest，必须满足源 digest =
   目标 digest = lock；不一致直接失败。`mirror-caddy:2` 必须与 lock 的 caddy 一字不差。
3. 登录 GHCR 后执行 `make images-pin`。脚本 inspect 五个自建包的 `latest`，
   全部解析成功后才原子回写，并在写入前检查合并 Compose 配置。
   `router` / `jjb` / `dnsmasq` / `jenkins` 增加到 `docker-compose.ghcr.yml` 的服务段，
   harness 存在该文件的标准 Compose 扩展 `x-m0-test-image`，供 GHCR bats 使用。
   默认解析 `latest`；合入前验收可显式运行
   `IMAGES_TAG=sha-<工作流的7位提交号> make images-pin`，只选择已推送成功的那次产物，
   不必提前合入 main 或伪造 `latest`。重复执行结果相同；失败会提示先跑 `images.yml`。提交真实 pins；
   不改变 `tests/images.lock` 和基础 Compose 的上游 digest。

手动触发示例（工作流首次引入时需先注册，或合入默认分支；仅 dispatch/schedule 的
新工作流在尚未注册时会返回 404）：

```sh
gh workflow run images.yml --ref main
gh workflow run mirror.yml --ref main -f mode=all
gh run list --limit 10
make images-pin
```

`mode=amd64` 用 `--override-os linux --override-arch amd64`，只搬单架构，
目标标签是 `<上游tag>-amd64`，与 all 模式标签隔离，防止定时任务覆盖多架构索引。
**单架构搬运后 digest 会变，不能沿用上游 digest**；单架构源也可能恰好相同。
Summary 如实列出两者，不把相等当成功条件，也不把不同解释为「换算」。
amd64 模式不负责填充当前 GHCR override；要使用它必须另行显式锁定新目标 digest，
不能把该 digest 写回上游 lock。213 首次切换必须使用 all 模式。

## 213 使用（不需要登录）

13 个包全部 public，**拉取不需要任何凭据**，213 上不用 `docker login`：

```sh
docker pull ghcr.io/zeek-zhao/orgflow-devops/router:24.04-v1
```

需要凭据的只有「推」这一侧——`images.yml` / `mirror.yml` 用工作流内置的
`GITHUB_TOKEN`（`packages: write`）推送，同样不需要人工登录。
`tests/bats/18_public.bats` 会匿名取一遍 manifest，谁把包改回 private 就会红。

已经搬运且 pin 后：

```sh
make render
# 有正确配置的 .env；--no-build 避免已有 build 字段触发本地重建
USE_GHCR=1 make up
# 等价的显式 Compose 调用
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml --env-file .env up -d --no-build
USE_GHCR=1 make test-bats
```

`USE_GHCR=1` 为 Make 的 Compose 命令叠加 GHCR override。
测试同时从 GHCR 拉取锁定的 router/上游服务/harness，不再本地构建；
`M0_COMPOSE_EXTRA` 把额外 override 文件路径传给 DinD 和 bats 的 Compose helper，
最后仍以已验证宿主镜像的 config ID override 预灌内层 daemon。
不要绕过首次 pin：未 pin 的文件只包含七个上游服务，可以通过 Compose 配置检查，
但不能在没有 Hub 缓存的 213 上完成自建镜像部署。

不设置 `USE_GHCR` 时保留本地构建行为。213 缺 Hub 镜像立即报错，不尝试不可达的网络；
GitHub 托管 runner 无缓存，工作流显式设置 `ALLOW_PULL_DOCKER_HUB=1` 才允许拉取。

**`USE_GHCR=1` 时 `up` 必须带 `--no-build`，不能带 `--build`。** override 里 `image:` 是
digest 引用（`repo:tag@sha256:...`），compose 若去构建就会拿它当 tag 写，直接报
`refusing to create a tag with a digest reference`。`dnsmasq` / `router` / `jjb` 三个服务
有 `build:`，`dnsmasq` 是第一批，所以最先炸。`scripts/deploy.sh` 用 `BUILD_FLAG` 跟着
`USE_GHCR` 走，`make up` 早就是这么做的；这条路径直到 2026-10-31 才第一次在真机上跑，
CI 的 harness 是 `compose up --no-build --pull never` 直连、不经过 `deploy.sh`，覆盖不到。

## GHCR 配额

私有包的存储/流量可能计入账号配额并按量计费，注意账户的 Packages 用量、
预算和最新 GHCR 计费政策。多架构搬运以及持续新增 sha 标签可能增加占用；
按保留策略清理未使用版本时，**不能删除仍被 digest pin 引用的版本**。
`mirror-*` 只搬运公开上游镜像，不混入私有源码或凭据；有需要可在包设置中
将其可见性改为 public 以节省配额，但应确认上游许可证和组织策略。
自建包的公开性单独评估，不要为了省配额自动公开仓库产物。

## 首次验收（Issue #12）

| 项目 | 实测结果 |
|---|---|
| 自建镜像发布 | [Images 41087100418](https://github.com/zeek-zhao/orgflow-devops/actions/runs/41087100418) 成功，三个私有包均可 inspect，`digests.txt` 已汇总 |
| PR 仅构建 | [Images 41087085853](https://github.com/zeek-zhao/orgflow-devops/actions/runs/41087085853) 成功，未登录或推送 |
| PR Python + bats | [Test 41087898694](https://github.com/zeek-zhao/orgflow-devops/actions/runs/41087898694) 成功，原 56 项加 12 项 CI 回归测试、9/9 bats |
| 八项全架构搬运 | [Mirror 41087890087](https://github.com/zeek-zhao/orgflow-devops/actions/runs/41087890087) 手动 `mode=all`，全部成功 |
| GHCR 全链路 | 本地 `USE_GHCR=1 make test-bats` 为 9/9；三包按 `sha-ba5e76e` pin 两次，文件字节一致 |

实际 inspect `mirror-caddy:2` 与 lock 均为
`sha256:36c24ad91a7ff7bc4c87fe22bfa8df3c4b18da0773d73fc12ee2c52b98c0bb7e`。
基础 Compose 和 `tests/images.lock` 未修改。两种 Compose 配置、Bash 语法、
四个 YAML 解析检查及默认本地构建模式的 9/9 bats 同样通过。
