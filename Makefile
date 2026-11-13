# orgflow-devops — M0 最小核心
SHELL := /bin/bash
COMPOSE ?= docker compose
ENV_FILE ?= .env
# agent 容器里的 jenkins(1000) 要驱动宿主 daemon，必须拿到 docker.sock 的 gid
# （compose 里是 group_add: ${DOCKER_GID}）。deploy.sh 与 harness 会自己探测，
# 这里是为了 `make up` 直接起栈时也有值 —— 少一个地方就会静默退回 0，
# 表现成 job 里「找不到网络 orgflow」。
DOCKER_GID ?= $(shell stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)
export DOCKER_GID
# agent 的 sshd host key 公钥：JCasC 的 manuallyProvidedKeyVerificationStrategy 只认
# 「算法 base64」两列，.pub 第三列是注释必须切掉。空值会让 JCasC 直接启动失败
# （该类构造时就 parseKey），所以 deploy.sh / harness / 这里三处都要导出。
JENKINS_AGENT_HOST_KEY ?= $(shell awk 'NR==1{print $$1" "$$2}' secrets/agent_host_key.pub 2>/dev/null)
export JENKINS_AGENT_HOST_KEY
# 镜像只有一个来源：GitHub Actions 构建推进 GHCR，本地只拉不建。
# 为什么默认改为 1：仓库要对公众开放，任何人 clone 下来都应拿到**同一批镜像**；
# 默认本地构建时，同一份源码在不同机器上会编译出不同结果，也就没有可复现性可言。
# 本地构建仍然保留，但要显式 `make build-local` / `USE_GHCR=0 make deploy` ——
# 「默认」和「允许」是两件事，出问题时要能从命令本身看出走的是哪条路。
USE_GHCR ?= 1
ifeq ($(USE_GHCR),1)
COMPOSE += -f docker-compose.yml -f docker-compose.ghcr.yml
# 不带覆盖层的 Compose：仅供 build-local 使用，避免构建路径被 digest 锁定的
# image: 干扰（拿 `tag@sha256:...` 去 build 会被 compose 拒绝打 tag）。
COMPOSE_LOCAL = docker compose
else
COMPOSE_LOCAL = $(COMPOSE)
endif

.PHONY: help render deploy doctor up down jobs jobs-test backup restore backup-verify lint check check-all test test-groovy test-bats images-lock images-pin images-guard build-local hooks identity-check hosts ca clean check-jenkins-image check-pins docs-check sbom cve links ldap-passwords ldap-apply ldap-init init labels-sync redaction

help:
	@echo "make render   渲染 routes.yaml -> out/Caddyfile"
	@echo "make deploy   起 M0 底座（Jenkins/权限/路由/Caddy）；SERVICE=xxx 单服务；Nexus 由 job nexus-deploy 部署"
	@echo "make doctor   只读环境自检（Docker/端口/配置/磁盘/镜像，不启动容器）"
	@echo "make hosts    IP=192.168.0.50 生成 /etc/hosts 片段（域名路由必需）"
	@echo "make ca       导出并安装 Caddy 内部 CA 根证书"
	@echo "make jobs     推送参数化 deploy/backup/restore Job 到 Jenkins"
	@echo "make jobs-test 本地渲染校验三个 Job（不连接 Jenkins，无需 .env）"
	@echo "make backup   触发一次全量备份（本地脚本）"
	@echo "make restore  SERVICE=ldap BACKUP_FILE=包路径（交互确认覆盖）"
	@echo "make backup-verify BACKUP_FILE=包路径（只校验）"
	@echo "make lint     静态检查（shellcheck/yamllint）"
	@echo "make test     跑 Python 侧测试（路由/导入/Job 定义/文档四段覆盖/文档登记册）"
	@echo "make docs-check 只跑文档登记册门禁（IEEE 828：双向一致/ID唯一/状态见证）"
	@echo "make sbom     生成声明式 SBOM（SPDX 2.3，输出 out/sbom.spdx.json）"
	@echo "make cve      对本项目分发的每个镜像跑 trivy（先出账不阻断；未装 trivy 会明确失败）"
	@echo "make links    校验仓库内文档链接自洽（无 404）"
	@echo "make redaction 公开面门禁：内网标识/凭据形态/内部流程文档（转 public 前必跑）"
	@echo "make ldap-passwords 按 .env 的 ORGFLOW_INITIAL_PASSWORD 重算 users.ldif 哈希"
	@echo "make ldap-init  初始化 LDAP 目录（bootstrap+ldap-apply，幂等；#140）"
	@echo "make init       deploy 后一键收尾：LDAP 初始化→jobs→Nexus→入口清单（#140）"
	@echo "make check-jenkins-image 静态校验 plugins.txt 必装项 + Dockerfile 用 jenkins-plugin-cli（#90）"
	@echo "make images-guard 镜像来源闸门：digest 锁死 / pinned-at 可解析 / 镜像未落后于源码（deploy 前置）"
	@echo "make test-groovy 跑共享库行为测试（需要 groovy，缺失则跳过）"
	@echo "make test-bats DinD 容器内跑 10 个 compose 服务 + job 部署的 nexus（KEEP=1 保现场）"
	@echo "make images-lock 从本地镜像 digest 更新 tests/images.lock"
	@echo "make images-pin 从 GHCR 回写自建镜像 digest（先跑 images.yml）"
	@echo "镜像默认来自 GHCR（USE_GHCR=1）：由 images.yml 构建推送，本地只拉不建"
	@echo "make build-local 显式本地构建（只供本地验证，不推 GHCR）"
	@echo "USE_GHCR=0 make deploy 使用本地构建的镜像部署"
	@echo "make hooks    安装 git 钩子（提交身份校验 + 主干保护），新克隆必做"
	@echo "make identity-check 校验仓库提交身份是否唯一（见 CONTRIBUTING.md）"
	@echo "make down     停止并移除容器"

# 域名取自 $(ENV_FILE)（缺省回落 routes.yaml 的值）；render-dex.sh 自己会读 .env
render:
	@mkdir -p out
	@GATEWAY_DOMAIN="$$(sed -n 's/^GATEWAY_DOMAIN=//p' $(ENV_FILE) 2>/dev/null | tail -1 | tr -d '\042\047')" \
	 python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile
	@ENV_FILE=$(ENV_FILE) bash scripts/render-dex.sh
	@echo "rendered out/Caddyfile + out/dex/config.yaml"

# 域名解析片段（宿主机 / 局域网机器用）；IP= 可指定，默认自动探测
hosts:
	@bash scripts/gen-hosts.sh $(IP)

# 导出并安装 Caddy 内部 CA 根证书
ca:
	@bash scripts/ca-install.sh

deploy: render images-guard
	@ENV_FILE="$(ENV_FILE)" COMPOSE="$(COMPOSE)" USE_GHCR="$(USE_GHCR)" bash scripts/deploy.sh $(if $(SERVICE),--service $(SERVICE),)

doctor:
	@ENV_FILE="$(ENV_FILE)" COMPOSE="$(COMPOSE)" python3 scripts/doctor.py

up: images-guard
	$(COMPOSE) --env-file $(ENV_FILE) up -d $(if $(filter 1,$(USE_GHCR)),--no-build)

# 本地构建（显式）：改了 Dockerfile 想立刻验证时用，产物只在本地，**不推 GHCR**。
# 建完用 `USE_GHCR=0 make deploy` 起来；验证通过后走正常流程（PR → CI → images-pin），
# 不要拿本地镜像去部署共享环境。
build-local:
	@echo "== 本地构建（USE_GHCR=0）：产物不推 GHCR，只供本地验证 =="
	$(COMPOSE_LOCAL) build router dnsmasq jjb jenkins jenkins-agent
	@echo "== 完成；用 USE_GHCR=0 make deploy 部署这套本地镜像 =="

down:
	$(COMPOSE) --env-file $(ENV_FILE) down

# 网关是内部 CA 自签：导出根证书分发给需要直连网关的客户端（浏览器/局域网机器）。
# jjb 已不走网关（#30），此目标不再是 jobs 的前置。
out/ca/root.crt:
	@bash scripts/ca-install.sh --export

# jjb 走 compose 内网 http://jenkins:8080（#30）：不经网关，无需先装 CA
jobs:
	@bash scripts/gen-jjb-conf.sh "$(ENV_FILE)"
	$(COMPOSE) --env-file "$(ENV_FILE)" run --rm jjb jenkins-jobs --conf /repo/.jjb/jenkins_jobs.ini update config/job_definitions/

jobs-test:
	@bash scripts/gen-jjb-conf.sh "$(ENV_FILE)" --placeholder
	$(COMPOSE) run --rm -T jjb jenkins-jobs --conf /repo/.jjb/jenkins_jobs.ini test --config-xml -o /repo/.jjb/rendered config/job_definitions/

backup:
	@bash scripts/backup.sh --all

restore:
	@test -n "$$SERVICE" && test -n "$$BACKUP_FILE" || { echo "必须显式传 SERVICE 和 BACKUP_FILE" >&2; exit 1; }
	@read -r -p "将停服并覆盖 $$SERVICE 数据；输入 YES 继续: " confirm && \
		test "$$confirm" = YES || { echo "未确认，取消恢复" >&2; exit 1; }; \
		bash scripts/restore.sh --service "$$SERVICE" --file "$$BACKUP_FILE" --force

backup-verify:
	@test -n "$$BACKUP_FILE" || { echo "必须传 BACKUP_FILE" >&2; exit 1; }
	@bash scripts/backup.sh --verify "$$BACKUP_FILE"

restore backup-verify: export SERVICE := $(SERVICE)
restore backup-verify: export BACKUP_FILE := $(BACKUP_FILE)

lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh .github/scripts/*.sh || echo "shellcheck 未安装，跳过"
	@command -v yamllint >/dev/null && yamllint config services docker-compose.yml || echo "yamllint 未安装，跳过"

# 门禁分层：check 是 pre-commit 那一层（几秒、无 docker），check-all 是 pre-push 那一层。
# 定义在 scripts/ 里而不是这里，因为这台开发机上没有 make —— 钩子不能依赖 make。
# 具体跑什么、为什么这么分层，见两个脚本的抬头注释。
check:
	@bash scripts/check-fast.sh

check-all:
	@bash scripts/check-all.sh

test: check-jenkins-image
	@python3 -m py_compile services/router/render.py
	@python3 services/router/test_render.py
	@python3 services/auth/test_bootstrap.py
	@python3 scripts/test_deploy.py
	@python3 scripts/test_jobs.py
	@python3 scripts/test_backup.py
	@python3 scripts/test_nexus_archive.py
	@python3 scripts/test_ci.py
	@python3 scripts/test_image_source.py
	@python3 scripts/test_docs.py
	@python3 scripts/test_homepage_config.py
	@python3 scripts/test_service_doc_sections.py
	@python3 scripts/test_job_pipelines.py
	@python3 scripts/migrate_identity.py --verify
	@python3 scripts/test_ldif_passwords.py
	@python3 scripts/test_ldap_set_passwords.py
	@python3 scripts/test_labels.py
	@python3 scripts/check-actions-pinned.py .
	@python3 scripts/test_plugin_licenses.py
	@$(MAKE) --no-print-directory docs-check
	@echo "python syntax ok"

# 文档配置管理门禁（IEEE 828 轻量落地）：双向一致性、DOC-ID 唯一、状态与见证匹配，
# 复审超期只报 WARN。规则见 docs/文档规范.md，清单见 docs/文档登记册.md。
# 反证：删掉登记册里任意一行，这条必须红；补回去复绿。
docs-check:
	@python3 scripts/check_docs_meta.py

# 声明式 SBOM（SPDX 2.3）。组件取自 compose/nexus 脚本的 digest，许可证取自
# scripts/gen-sbom.py 的 DECLARED 表（依据 THIRD_PARTY_NOTICES.md）。
sbom:
	@python3 scripts/gen-sbom.py out/sbom.spdx.json

# CVE 扫描：先出账不阻断。未装 trivy 时明确报错退出，不让「没扫」被当成「扫过且干净」。
cve:
	@bash scripts/cve-scan.sh

# 文档链接自洽：仓内任何 .md 指向不存在的路径都算错。
# 单仓化（#131）之前这一步校验的是「导出目录」，因为公开面是另一个仓；
# 现在公开面就是本仓，DEST 这个参数没有意义了。
links:
	@python3 scripts/check_export_links.py .

# 公开面门禁：仓库要能被任何人 clone，转 public 前必跑。
redaction:
	@bash scripts/check-public-redaction.sh .

# 目录初始口令：仓库只存 {SSHA} 哈希，真值在 .env。
# 两处不一致的表现是「账号密码明明对，bind 却返回 49」，所以做成一条命令而不是手工 slappasswd。
# 注意：这条只重算**仓库里的 LDIF**，对已经存在的目录条目无效 —— 运行中的目录用 ldap-apply。
ldap-passwords:
	@set -e; \
	if [ ! -f "$(ENV_FILE)" ]; then echo "✗ 缺少 $(ENV_FILE)；先跑 make deploy 生成"; exit 1; fi; \
	pw=$$(sed -n 's/^ORGFLOW_INITIAL_PASSWORD=//p' "$(ENV_FILE)" | tail -1); \
	if [ -z "$$pw" ]; then \
		echo "✗ $(ENV_FILE) 里没有 ORGFLOW_INITIAL_PASSWORD；先在 .env 里填一个（≥12 字符）"; \
		exit 1; \
	fi; \
	ORGFLOW_INITIAL_PASSWORD="$$pw" python3 scripts/gen-ldif-passwords.py >/dev/null; \
	echo "✓ users.ldif 的 {SSHA} 已按 $(ENV_FILE) 的 ORGFLOW_INITIAL_PASSWORD 重算"
	@echo "  目录已经存在时这一步不会改运行中的口令；要生效再跑 make ldap-apply"

# 把 .env 的初始口令真正设到**运行中的目录**（ldapmodify）。
# 为什么单独一条：目录建好之后改 LDIF 不生效（ldapadd 对已存在的 DN 只报 already exists，
# bootstrap 当警告吞掉），而「改 LDIF 就算改了口令」是这套栈最容易踩的误解。
ldap-apply:
	@bash scripts/ldap-set-passwords.sh
# #140：全新部署最容易漏的两步（bootstrap 空目录 + 初始口令落运行中的目录）
# 串成一条命令。两步都幂等：bootstrap 对已存在 DN 只吞警告，ldap-apply 重设口令。
ldap-init:
	@$(COMPOSE) --env-file $(ENV_FILE) exec -T ldap bash /opt/orgflow-auth/bootstrap-ldif.sh
	@$(MAKE) --no-print-directory ldap-apply
# #140 一键收尾：deploy 之后把「LDAP 初始化 → 推 Job → 起 Nexus」串起来，
# hosts/CA 只自检提示不代做（root 边界）。实现与每步幂等性见 scripts/init.sh。
init:
	@ENV_FILE="$(ENV_FILE)" bash scripts/init.sh

# 标签真本在 .github/labels.json；这条把差异推到 GitHub（幂等，只增改不删）。
# 为什么需要人工触发而不是 CI：标签属于仓库外部状态，改它要写权限，
# 不该让每次 PR 都有权改 issue 台账。
labels-sync:
	@python3 scripts/sync-labels.py

# #90 / REQ-M0-B1：Jenkins 镜像静态自检。本轮不构建镜像，容器内插件清单无法实测，
# 用「清单必含项 + Dockerfile 用 jenkins-plugin-cli 安装」替代（见 docs/M0-镜像与CI.md）。
# 反证：从 plugins.txt 删掉 workflow-aggregator，这条必须红，恢复后复绿。
check-jenkins-image:
	@set -e; \
	for plugin in workflow-aggregator git credentials ldap configuration-as-code; do \
		count=$$(grep -cx "$$plugin" services/jenkins/plugins.txt 2>/dev/null || true); \
		count=$${count:-0}; \
		if [ "$$count" -ne 1 ]; then \
			echo "✗ 镜像自检失败: plugins.txt 的 $$plugin 出现 $$count 次（应为 1）"; \
			exit 1; \
		fi; \
	done; \
	if ! grep -q 'jenkins-plugin-cli --plugin-file' services/jenkins/Dockerfile; then \
		echo "✗ 镜像自检失败: Dockerfile 未用 jenkins-plugin-cli --plugin-file 安装 plugins.txt"; \
		exit 1; \
	fi; \
	echo "✓ 镜像自检通过: 5 项必装插件齐备，Dockerfile 用 jenkins-plugin-cli 安装"

# #90 / 镜像来源闸门：USE_GHCR=1 时禁止把「源码已改、镜像没重建」的状态部署出去。
# 三条判据见 scripts/check-image-source.sh：digest 锁死无占位 / pinned-at 可解析 /
# 镜像上下文自 pinned-at 以来无改动。反证：改一下 services/jenkins/Dockerfile
# 再跑 make deploy，这条必须红；git checkout 回去复绿。
images-guard:
	@USE_GHCR="$(USE_GHCR)" bash scripts/check-image-source.sh

# 旧名字保留：外部脚本/文档里还写着 make check-pins
check-pins: images-guard

# test-bats 验证的是「**本次源码**构建出来的栈能不能起来」，所以它必须本地构建。
# 用 GHCR 镜像跑 bats 是自欺：GHCR 上是上一个提交的镜像，PR 改的东西根本不在里面。
# 因此这里独立一个开关（缺省 0），不跟随全局 USE_GHCR —— 否则把默认值改成 1
# 之后，bats 会静默退化成「测旧镜像」，而它恰好是这套栈唯一的真验证。
TEST_BATS_GHCR ?= 0
# 只在「跑 test-bats 且显式传了 USE_GHCR」时警告：
#   - $(origin USE_GHCR) 要覆盖 environment 与 command line 两种写法
#     （`USE_GHCR=1 make …` 是 environment，`make USE_GHCR=1 …` 是 command line）；
#   - 用 MAKECMDGOALS 过滤，否则 `USE_GHCR=1 make deploy` 也会打出与它无关的警告。
ifneq ($(filter test-bats,$(MAKECMDGOALS)),)
ifneq ($(filter environment command line,$(origin USE_GHCR)),)
ifneq ($(USE_GHCR),$(TEST_BATS_GHCR))
$(warning USE_GHCR=$(USE_GHCR) 对 test-bats 无效：bats 只测本地构建。要跑 GHCR 镜像请用 TEST_BATS_GHCR=1)
endif
endif
endif

test-bats:
	@USE_GHCR="$(TEST_BATS_GHCR)" bash tests/images.sh ensure
	@if [[ "$(TEST_BATS_GHCR)" != 1 ]]; then docker build -t orgflow/m0-test:24.04-v1 tests/harness; fi
	@image=$$(USE_GHCR="$(TEST_BATS_GHCR)" bash tests/images.sh harness-image) && \
		docker run --rm --privileged --name orgflow-m0-test -e KEEP="$(KEEP)" \
		-e M0_COMPOSE_EXTRA="$(if $(filter 1,$(TEST_BATS_GHCR)),/repo/docker-compose.ghcr.yml)" \
		-v "$(CURDIR):/repo" -v /var/run/docker.sock:/host/docker.sock \
		-v m0-dind:/var/lib/docker "$$image"

images-lock:
	@bash tests/images.sh update

images-pin:
	@bash scripts/pin-images.sh

# 共享库行为测试只依赖 groovy 本身（用 GroovyShell + metaClass 打桩，无外部 jar）
test-groovy:
	@if command -v groovy >/dev/null 2>&1; then \
		groovy shared-library/test/stepsTest.groovy; \
	else \
		echo "groovy 未安装，跳过（Ubuntu: apt install groovy）"; \
	fi

# #117 真机事故：绝不 `rm -rf out`。
# router 与 caddy 都把 ./out 作为 bind mount 挂进容器；删掉目录再重建会换 inode，
# 容器仍持有被删除的旧 inode（nlink=0），watch 每轮报 ENOENT 却永远不恢复，
# 而当时的 /healthz 只看「读到几条路由」，照样报绿 —— 配置改了、Caddy 没更新。
# 另外 out/ca/ 里是网关根证书，删了整条 TLS 链就断了。
# 只删渲染产物，保留目录本身与 CA。
clean:
	@rm -f out/Caddyfile out/Caddyfile.probe out/*.tmp
	@echo "已清理渲染产物（保留 out/ 目录与 out/ca/）"

# 新克隆必做：core.hooksPath 是本地配置，不会随 clone 生效
hooks:
	@git config core.hooksPath .githooks
	@chmod +x .githooks/*
	@echo "已安装钩子：$(shell ls .githooks | tr '\n' ' ')"
	@echo "钩子内容：pre-commit 校验提交身份，pre-push 拦主干 + 校验身份"

# 校验 author 是否唯一（main 上 committer 允许 GitHub 平台）
# --no-merges 必须保留：GitHub 为 PR 生成的合成合并提交，其 author 是
# 账号的 noreply 邮箱、committer 是 GitHub，属平台产物，不该计入身份校验。
#
# ★ 这条过滤**只管合并提交**。squash 合并的产物只有单父，--no-merges 不生效，
#   author 会被改写成 noreply 而这里照样红——2026-10-31 就这么红过一次（PR #25）。
#   而 squash 提交和 rebase 后的提交在脚本层面无法区分（都是单父 + committer 是
#   noreply），所以补不了：合并一律 rebase，见 CONTRIBUTING.md 第 1 节。
identity-check:
	@bad=0; \
	for ae in $$(git log --no-merges --format='%ae' | sort -u); do \
		if [ "$$ae" != "zeek.zhao@foxmail.com" ]; then echo "✗ author 异常: $$ae"; bad=1; fi; \
	done; \
	if [ "$$bad" = 0 ]; then echo "✓ author 唯一: zeek.zhao@foxmail.com"; else exit 1; fi
