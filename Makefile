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
ifeq ($(USE_GHCR),1)
COMPOSE += -f docker-compose.yml -f docker-compose.ghcr.yml
endif

.PHONY: help render deploy doctor up down jobs jobs-test backup restore backup-verify lint test test-groovy test-bats images-lock images-pin hooks identity-check hosts ca clean check-jenkins-image check-pins

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
	@echo "make test     跑 Python 侧测试（路由/导入/Job 定义/文档四段覆盖）"
	@echo "make check-jenkins-image 静态校验 plugins.txt 必装项 + Dockerfile 用 jenkins-plugin-cli（#90）"
	@echo "make check-pins 校验 tests/images.lock 无「待构建后回填」占位（USE_GHCR=1 上线闸门）"
	@echo "make test-groovy 跑共享库行为测试（需要 groovy，缺失则跳过）"
	@echo "make test-bats DinD 容器内跑 10 个 compose 服务 + job 部署的 nexus（KEEP=1 保现场）"
	@echo "make images-lock 从本地镜像 digest 更新 tests/images.lock"
	@echo "make images-pin 从 GHCR 回写自建镜像 digest（先跑 images.yml）"
	@echo "USE_GHCR=1 make up / test-bats 使用 GHCR 锁定镜像（包全 public，无需 docker login）"
	@echo "make hooks    安装 git 钩子（提交身份校验 + 主干保护），新克隆必做"
	@echo "make identity-check 校验仓库提交身份是否唯一（见 docs/提交规范.md）"
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

deploy: render
	$(if $(filter 1,$(USE_GHCR)),@$(MAKE) --no-print-directory check-pins)
	@ENV_FILE="$(ENV_FILE)" COMPOSE="$(COMPOSE)" USE_GHCR="$(USE_GHCR)" bash scripts/deploy.sh $(if $(SERVICE),--service $(SERVICE),)

doctor:
	@ENV_FILE="$(ENV_FILE)" COMPOSE="$(COMPOSE)" python3 scripts/doctor.py

up:
	$(if $(filter 1,$(USE_GHCR)),@$(MAKE) --no-print-directory check-pins)
	$(COMPOSE) --env-file $(ENV_FILE) up -d $(if $(filter 1,$(USE_GHCR)),--no-build)

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

test: check-jenkins-image
	@python3 -m py_compile services/router/render.py
	@python3 services/router/test_render.py
	@python3 services/auth/test_bootstrap.py
	@python3 scripts/test_deploy.py
	@python3 scripts/test_jobs.py
	@python3 scripts/test_backup.py
	@python3 scripts/test_ci.py
	@python3 scripts/test_docs.py
	@python3 scripts/test_homepage_config.py
	@python3 scripts/test_service_doc_sections.py
	@python3 scripts/test_job_pipelines.py
	@echo "python syntax ok"

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

# #90：tests/images.lock 里还有「待构建后回填」占位时禁止带占位上线。
# 本轮不构建不推送，digest 尚未产生；USE_GHCR=1 的 up / deploy 会先撞这条闸门。
check-pins:
	@if grep -v '^#' tests/images.lock | grep -q '待构建后回填'; then \
		echo "✗ tests/images.lock 仍有未回填的 digest 占位（待构建后回填）；先构建镜像并回填真实 digest，禁止上线"; \
		exit 1; \
	fi; \
	echo "✓ images.lock 无待回填占位"

test-bats:
	@USE_GHCR="$(USE_GHCR)" bash tests/images.sh ensure
	@if [[ "$(USE_GHCR)" != 1 ]]; then docker build -t orgflow/m0-test:24.04-v1 tests/harness; fi
	@image=$$(USE_GHCR="$(USE_GHCR)" bash tests/images.sh harness-image) && \
	docker run --rm --privileged --name orgflow-m0-test -e KEEP="$(KEEP)" \
		-e M0_COMPOSE_EXTRA="$(if $(filter 1,$(USE_GHCR)),/repo/docker-compose.ghcr.yml)" \
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

clean:
	rm -rf out

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
#   noreply），所以补不了：合并一律 rebase，见 docs/提交规范.md 第 1 节。
identity-check:
	@bad=0; \
	for ae in $$(git log --no-merges --format='%ae' | sort -u); do \
		if [ "$$ae" != "zeek.zhao@foxmail.com" ]; then echo "✗ author 异常: $$ae"; bad=1; fi; \
	done; \
	if [ "$$bad" = 0 ]; then echo "✓ author 唯一: zeek.zhao@foxmail.com"; else exit 1; fi
