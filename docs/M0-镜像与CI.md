# M0 镜像与 CI

## 三个工作流

| 工作流 | 职责 | 触发 |
|---|---|---|
| `images.yml` | Buildx 构建 router、jjb、m0-test、dnsmasq、jenkins、jenkins-agent，**只建改动真正落进去的那几个**（见「按改动裁剪」）；非 PR 推 GHCR，每项输出 digest，汇总为 `digests.txt` artifact | main push / PR，限定 `tests/harness/**`、`services/router/**`、`services/dnsmasq/**`、`tools/jjb/**`、`tools/jenkins/**`、`tools/jenkins-agent/**`、`.github/scripts/**` 和工作流本身；也可手动触发 |
| `mirror.yml` | skopeo 搬运 lock 中 7 个服务镜像和 Ubuntu 基座，逐项记录源/目标 digest | 手动（`mode=amd64` 默认 / `all`）；每周一 03:00 **UTC** 定时，默认 amd64 |
| `test.yml` | `make test`，再 `ALLOW_PULL_DOCKER_HUB=1 make test-bats`；30 分钟超时，失败上传 `bats-failure-log` | main push、所有 PR、手动 |

CI 仅用 `secrets.GITHUB_TOKEN` 登录 GHCR，镜像工作流需要 `packages: write`，
源码权限是 `contents: read`。PR 只构建，不登录、不推送；PR summary 中的 digest
不是已发布镜像，不能用于部署。测试中 `pipefail` 保留 bats 的失败状态，
`/tmp/bats-run.log` 包含构建、健康闸门及 TAP 输出。

> **#90 现状（本轮静态交付，未构建、未推送）**：Jenkins 的 compose 构建上下文已从
> `tools/jenkins` 迁到 `services/jenkins`（`docker-compose.yml` 的 `build.context`），
> 但 `images.yml` 的 `on.paths`、`.github/scripts/select-images.sh` 的映射表、
> `scripts/test_ci.py` 与 `tests/bats/00_stack.bats` 的路径断言仍指向 `tools/jenkins/**`。
> 这四处不在本卡改动范围内，**派单方合并时须同步**：否则 `services/jenkins/**` 的改动
> 不会触发 Images 工作流，213 会静默继续吃旧的 GHCR 镜像。详见文末「#90」节。

## 按改动裁剪（#53）

`on.paths` 只决定「跑不跑」，不决定「建几个」。`images.yml` 先跑一个 `select` job，
用 `.github/scripts/select-images.sh` 从 `git diff` 算出改动落在哪些镜像上下文里，
只把命中的填进 matrix：

| 镜像 | 上下文 | 触发路径 |
|---|---|---|
| `router` | `services/router` | `services/router/**` |
| `jjb` | `tools/jjb` | `tools/jjb/**` |
| `jenkins` | `tools/jenkins`（#90 起 compose 用 `services/jenkins`，映射待同步） | `tools/jenkins/**`（#90 起应为 `services/jenkins/**`，待同步） |
| `jenkins-agent` | `tools/jenkins-agent` | `tools/jenkins-agent/**` |
| `m0-test` | `tests/harness` | `tests/harness/**` |
| `dnsmasq` | `services/dnsmasq` | `services/dnsmasq/**` |

触发路径由 `<context>/**` 推导，因为六个上下文都是自包含目录。**这条依赖有断言守着**：
`test_ci.py` 检查每个 Dockerfile 都不许 `COPY ../`，否则构建会漏掉且没人发现。

**判断不了就全量**，不猜：`.github/**` 改动、`workflow_dispatch`、新建分支（`before` 全 0）、
算不出 diff。多建一轮是浪费，漏建一轮是事故 —— 213 拉不到 Docker Hub，只会吃到与源码
不一致的 GHCR 镜像。

无命中时 `any=false`，`build` / `digests` 用 `if` 跳过（空 `include` 会让 GitHub 直接报
`Matrix vector 'include' does not contain any values`）。

`test.yml` 和 `images.yml` 都带 `concurrency`，PR 上同分支连推取消上一轮；`main` 上不取消，
避免打断正在推 GHCR 的构建。**Test 的 DinD 不做路径跳过** —— 它是这套栈唯一的真验证。

包名前缀固定为小写 `ghcr.io/zeek-zhao/orgflow-devops/`：
自建包是 `router`、`jjb`、`m0-test`、`dnsmasq`、`jenkins`、`jenkins-agent`，标签为 `sha-<7位>`、`24.04-v1`，
以及只在默认分支生成的 `latest`。分支手动构建会更新 `24.04-v1`，不会更新 `latest`；
部署始终以 `@sha256:...` 锁定，标签只是可读提示。

`jenkins` / `jenkins-agent` 是**自建而非搬运**：上游镜像一个不带插件、一个不带 docker CLI，
而 213 拉不到 Docker Hub，**只能在 runner 上构建后推 GHCR**，`docker-compose.yml` 里是
`build:` 而不是 `image:`。`jenkins-agent` 只装 docker CLI 不装 daemon —— daemon 用宿主机的
（挂 `/var/run/docker.sock`）。

#90 起 `jenkins` 的新 tag 也登记进 `tests/images.lock`（digest 单一真源），但本轮未构建，
那一行的 digest 是「待构建后回填」占位而不是 sha256；`jenkins-agent` 仍不在 lock 里。

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
3. 登录 GHCR 后执行 `make images-pin`。脚本 inspect 六个自建包的 `latest`，
   全部解析成功后才原子回写，并在写入前检查合并 Compose 配置。
   `router` / `jjb` / `dnsmasq` / `jenkins` / `jenkins-agent` 增加到 `docker-compose.ghcr.yml` 的服务段，
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
# 默认就是 GHCR（USE_GHCR 缺省 1）；--no-build 避免 build 字段触发本地重建
make up
# 等价的显式 Compose 调用
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml --env-file .env up -d --no-build
make test-bats
```

`USE_GHCR` 缺省为 **1**：`make deploy` / `make up` / `make test-bats` 一律叠加
GHCR override 并从 registry 拉取，不再本地构建。
测试从 GHCR 拉取锁定的 router/上游服务/harness；
`M0_COMPOSE_EXTRA` 把额外 override 文件路径传给 DinD 和 bats 的 Compose helper，
最后仍以已验证宿主镜像的 config ID override 预灌内层 daemon。
不要绕过首次 pin：未 pin 的文件只包含七个上游服务，可以通过 Compose 配置检查，
但不能在没有 Hub 缓存的 213 上完成自建镜像部署。

**本地构建必须显式**：`make build-local`（产物不推 GHCR），起来用
`USE_GHCR=0 make deploy`。两条路径的作用不同，不是等价选项 ——
默认值必须保证「任何人 clone 下来拿到同一批镜像」，否则同源码在不同机器
编出不同结果，就没有可复现性可言。

本地构建路径下 213 缺 Hub 镜像会立即报错，不尝试不可达的网络；
GitHub 托管 runner 无缓存，工作流显式设置 `ALLOW_PULL_DOCKER_HUB=1` 才允许拉取。

### 镜像来源闸门（`scripts/check-image-source.sh`）

默认从 GHCR 拉之后，出现了一种新的失败模式，而且它长得像成功：

> 改了 `services/jenkins/Dockerfile`，没等 CI 跑完就 `make deploy`。
> Compose 顺利拉到**上一版**镜像，健康检查全绿，端点自检全绿，部署的却是旧代码。

闸门拦的就是这个。三条判据：

| 判据 | 失败表现 | 为什么用这个判据 |
|---|---|---|
| digest 全部 `@sha256` 锁定、`tests/images.lock` 无「待构建后回填」占位 | 浮动 tag 会拉到不同镜像 | 部署结果必须可复现 |
| `# pinned-at: <sha>` 存在且该提交在本地 | 无法判断镜像与源码的对应关系 | 这是唯一能回答「镜像过期没」的依据 |
| 镜像上下文自 `pinned-at` 以来无改动（含未提交改动） | 镜像落后于源码 | 见上 |

`pinned-at` 由 `scripts/pin-images.sh` 写入 `docker-compose.ghcr.yml` 头部，
值是产出这批 digest 的那次提交。**判据刻意不写成「HEAD 是否等于 origin/main」**：
改一行文档就会让两者不等，那种闸门天天误报，人很快学会无视它 —— 比没有更糟。
镜像上下文的定义与 `.github/workflows/images.yml` 的 `paths` 逐项一致。

没有 `.git` 元数据时（zip 解压的副本）只警告不失败：那种副本的 digest 与它
自己的源码同批产出，本来就无从比较，而「下载压缩包」是公开仓最常见的打开方式。

反证：改一个 `services/jenkins/Dockerfile` 再跑 `make deploy`，闸门必须红；
`git checkout -- services/jenkins/Dockerfile` 后复绿。测试见
`scripts/test_image_source.py`（建真仓库跑真 git，不用桩）。

**`USE_GHCR=1` 时 `up` 必须带 `--no-build`，不能带 `--build`。** override 里 `image:` 是
digest 引用（`repo:tag@sha256:...`），compose 若去构建就会拿它当 tag 写，直接报
`refusing to create a tag with a digest reference`。`dnsmasq` / `router` / `jjb` 三个服务
有 `build:`，`dnsmasq` 是第一批，所以最先炸。`scripts/deploy.sh` 用 `BUILD_FLAG` 跟着
`USE_GHCR` 走，`make up` 早就是这么做的；这条路径直到 2026-10-31 才第一次在真机上跑，
CI 的 harness 是 `compose up --no-build --pull never` 直连、不经过 `deploy.sh`，覆盖不到。

## 手动推送（本地构建 → GHCR，用 `$GITHUB_TOKEN`）

CI 侧 `images.yml` / `mirror.yml` 用工作流内置的 `GITHUB_TOKEN`（`packages: write`）
推送，不需要人工登录。只有在**本地手工构建并推送**时才需要下面这套；
照抄即可，令牌只从环境变量读，绝不落到文件、命令行参数或 shell 历史里。

```sh
# 1) 登录：--password-stdin 从管道读，不出现 -p（-p 会进 ps 与 history）
export GHCR_USER="${GHCR_USER:-zeek-zhao}"
export GITHUB_TOKEN="$(cat ~/.config/wb/github.token)"   # 或由 CI secret 注入
printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# 2) 构建 + 打 tag（命名空间固定 ghcr.io/<owner>/orgflow-devops/<组件>）
IMAGE="ghcr.io/zeek-zhao/orgflow-devops/router"
TAG="$(git rev-parse --short=7 HEAD)"
docker build -t "$IMAGE:$TAG" services/router
docker tag "$IMAGE:$TAG" "$IMAGE:24.04-v1"

# 3) 推送：sha 标签与可读标签各推一次
docker push "$IMAGE:$TAG"
docker push "$IMAGE:24.04-v1"

# 4) 退出登录，别把凭据留在 ~/.docker/config.json
docker logout ghcr.io
```

要点：

- **令牌权限**：classic PAT 需要 `write:packages`（推）与 `read:packages`（拉私有包）；
  没有该 scope 时 `docker push` 返回 403，报错文本里不会提 scope，容易被误判成网络问题。
- **构建位置**：213 / 214 出不了 Docker Hub（blob 被 reset），本地构建必须在不依赖 Hub
  的机器上做，或者改用 `mirror.yml` 的 `mode=all` 走 CI 搬运，不要试图在 213 上 `docker build` 拉基础镜像。
- **推完保持 public**：13 个包必须匿名可拉，`tests/bats/18_public.bats` 会走完全匿名路径取
  manifest，改回 private 会让 PR 阶段直接红。
- **digest 回写**：手工推送产生的 digest 与 `tests/images.lock` 不是自动同步的，
  要参与部署仍须 `make images-pin`（见上一节），不要手改 lock。

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

---

## #90 · 自定义 Jenkins 插件镜像（本轮静态交付）

REQ-M0-B1 让 Jenkins 镜像自带常用插件，装机即可用，不靠人工在 UI 点装。

**新增 / 改动**：`services/jenkins/Dockerfile`、`services/jenkins/plugins.txt`；
`docker-compose.yml` 的 jenkins `build.context` 切到 `./services/jenkins`；
`docker-compose.ghcr.yml` 补新 tag / 回填说明；`tests/images.lock` 新增 jenkins 行；
`Makefile` 加两条自检；本文与 `docs/services/jenkins.md` 同步。

**默认插件清单**（`services/jenkins/plugins.txt`，纯列表、不钉版本）：
`workflow-aggregator`、`git`、`credentials`、`credentials-binding`、`plain-credentials`、
`ssh-slaves`、`ldap`（#90 新增）、`configuration-as-code`。Dockerfile 用
`jenkins-plugin-cli --plugin-file` 把它们装进 `/usr/share/jenkins/ref/plugins`。

**本轮不构建、不推送镜像**（不碰线上栈），因此验收里「容器内插件清单」无法实测，
改用静态检查替代，并真做反证：

| 项 | 手段 | 判据 |
|---|---|---|
| 插件清单必含项 | `make check-jenkins-image`（挂进 `make test`） | 5 项各出现 1 次 + Dockerfile 用 `jenkins-plugin-cli --plugin-file` |
| 反证 | 从 plugins.txt 删掉 `workflow-aggregator` 再跑 `make test` | 必须红；恢复后复绿 |
| `grep -c "workflow-aggregator" services/jenkins/plugins.txt` | 直接 grep | `1` |
| `docker compose config` | `-f docker-compose.yml -f docker-compose.ghcr.yml config -q` | 退出码 0 |

**digest 诚实占位**：24.04-v2 尚未构建，拿不到真实 digest，**不编造 sha256**。
`tests/images.lock` 的 jenkins 行写成明确的「待构建后回填」文字占位。已发布的
`24.04-v1@sha256:2e211...` 在 `docker-compose.ghcr.yml` 里原样保留、未改动。

两道闸门防止带占位上线：

1. `tests/images.sh ensure` 要求 GHCR image 为 `@sha256:[a-f0-9]{64}`，占位行会让
   `USE_GHCR=1` 的 `make test-bats` / 准备阶段直接失败；
2. `make check-pins`（检查 lock 非注释行是否含占位）挂在 `USE_GHCR=1` 的 `up` / `deploy`
   前置，命中即 `exit 1`。

`USE_GHCR=1` 时 `make up` / `deploy` 仍必须 `--no-build`：override 里的 `image` 是 digest
引用，带 `--build` 会报 `refusing to create a tag with a digest reference`。本轮新增的
`build.context` 不影响这条约束。

**回填流程（留给构建轮）**：`images.yml` 构建并推 24.04-v2 → 把真实 digest 写入
`tests/images.lock` 与 `docker-compose.ghcr.yml` 的 `jenkins.image` → 去掉占位 →
`make images-pin` 复核 → 才允许 `USE_GHCR=1 make deploy`。

**本轮未验证项**（诚实声明）：
- 容器内插件清单（`jenkins-plugin-cli --list` / `ls /usr/share/jenkins/ref/plugins`）——未构建镜像；
- 新镜像 digest、GHCR 可复现性与 24.04-v2 是否真的发布——未构建、未推送；
- `images.yml` 是否真的构建 `services/jenkins`——见下「待同步」；
- DinD bats（`make test-bats`）——本地跑不了，且占位期间 `ensure` 会红，属预期闸门。

**待同步（派单方合并时处理，不在本卡范围）**：当前 CI 裁剪链路仍指向旧上下文，
与 `docker-compose.yml` 的 `services/jenkins` 分叉。需同步这四处，否则
`services/jenkins/**` 的改动不触发 Images 工作流，213 会静默吃旧 GHCR 镜像：

| 文件 | 现状 | 应改为 |
|---|---|---|
| `.github/workflows/images.yml` | `on.paths`: `tools/jenkins/**`（push + pull_request 两处） | `services/jenkins/**` |
| `.github/scripts/select-images.sh` | `jenkins` → `tools/jenkins` | `jenkins` → `services/jenkins` |
| `scripts/test_ci.py` | `EXPECTED` 与 3 处用例路径写 `tools/jenkins` | `services/jenkins` |
| `tests/bats/00_stack.bats` | FROM 断言读 `tools/jenkins/Dockerfile` | `services/jenkins/Dockerfile` |

`tools/jenkins/` 目录本轮保留原样（上述四处仍引用它），待同步完成后由派单方决定是否清理。
