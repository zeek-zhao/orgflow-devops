# M0 镜像与 CI

## 三个工作流

| 工作流 | 职责 | 触发 |
|---|---|---|
| `images.yml` | Buildx matrix 构建 router、jjb、m0-test、dnsmasq；非 PR 推 GHCR，每项输出 digest，汇总为 `digests.txt` artifact | main push / PR，限定 `tests/harness/**`、`services/router/**`、`services/dnsmasq/**`、`tools/jjb/**` 和工作流本身；也可手动触发 |
| `mirror.yml` | skopeo 搬运 lock 中 7 个服务镜像和 Ubuntu 基座，逐项记录源/目标 digest | 手动（`mode=amd64` 默认 / `all`）；每周一 03:00 **UTC** 定时，默认 amd64 |
| `test.yml` | `make test`，再 `ALLOW_PULL_DOCKER_HUB=1 make test-bats`；30 分钟超时，失败上传 `bats-failure-log` | main push、所有 PR、手动 |

CI 仅用 `secrets.GITHUB_TOKEN` 登录 GHCR，镜像工作流需要 `packages: write`，
源码权限是 `contents: read`。PR 只构建，不登录、不推送；PR summary 中的 digest
不是已发布镜像，不能用于部署。测试中 `pipefail` 保留 bats 的失败状态，
`/tmp/bats-run.log` 包含构建、健康闸门及 TAP 输出。

包名前缀固定为小写 `ghcr.io/zeek-zhao/orgflow-devops/`：
自建包是 `router`、`jjb`、`m0-test`、`dnsmasq`，标签为 `sha-<7位>`、`24.04-v1`，
以及只在默认分支生成的 `latest`。分支手动构建会更新 `24.04-v1`，不会更新 `latest`；
部署始终以 `@sha256:...` 锁定，标签只是可读提示。

搬运包名扁平化为 `mirror-caddy`、`mirror-jenkins`、`mirror-openldap`、
`mirror-phpldapadmin`、`mirror-dex`、`mirror-oauth2-proxy`、`mirror-nexus`、
`mirror-ubuntu`。搬运源使用 `tests/images.lock` 的 digest，避免可变上游 tag
移动导致 override 的 digest 在 GHCR 不存在；升级仍按测试文档更新 lock。

## 首次发布、搬运、回写

1. push 并合入 main，等待 `images.yml` 绿色（路径过滤未命中时，在 main 手动运行）。
   可在 Summary / `digests.txt` 查看四个产物。分支构建不生成 `latest`，不能代替此步骤。
2. 手动执行 `mirror.yml`，**选择 `mode=all`**，等待八项完成。
   `--all --preserve-digests` 保留多架构索引与 manifest，必须满足源 digest =
   目标 digest = lock；不一致直接失败。`mirror-caddy:2` 必须与 lock 的 caddy 一字不差。
3. 登录 GHCR 后执行 `make images-pin`。脚本 inspect 四个自建包的 `latest`，
   全部解析成功后才原子回写，并在写入前检查合并 Compose 配置。
   `router` / `jjb` / `dnsmasq` 增加到 `docker-compose.ghcr.yml` 的服务段，
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

## 213 登录和使用

私有包需要有包读取权限的 PAT（至少 `read:packages`；包还需授予对应账号访问权限）。
通过密码管理器或安全交互获取 PAT，再从 stdin 登录，不要把令牌写进命令、仓库或工作流：

```sh
docker login ghcr.io -u <user> --password-stdin
```

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
不会改变原有十一个 bats 断言。

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
