# orgflow-devops — M0 最小公司级可用 Jenkins 开发系统
#
# 只有一条原则：**同一个结论必须能用一条命令复现**。
# 每条目标都在下面 `help` 里说清「做什么」，细节在 docs/。
SHELL := /bin/bash
COMPOSE ?= docker compose

# 唯一人工维护的配置是 config/orgflow.yml；out/runtime.env 是它渲染出来的
# 只读产物（由 scripts/10-render-config.sh 生成），compose 只认它。
# 不再有 .env —— 「改了配置没生效」这个坑从根上没了。
RUNTIME_ENV ?= out/runtime.env
ENV_FILE := $(RUNTIME_ENV)

# agent 容器里的 jenkins(1000) 要驱动宿主 daemon，必须拿到 docker.sock 的 gid
# （compose 里是 group_add: ${DOCKER_GID}）。deploy 脚本与 harness 会自己探测，
# 这里是为了 `make up` 直接起栈时也有值 —— 少一个地方就会静默退回 0，
# 表现成 job 里「找不到网络 orgflow」。
DOCKER_GID ?= $(shell stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)
export DOCKER_GID
# agent 的 sshd host key 公钥：JCasC 的 manuallyProvidedKeyVerificationStrategy 只认
# 「算法 base64」两列，.pub 第三列是注释必须切掉。空值会让 JCasC 直接启动失败
# （该类构造时就 parseKey），所以 deploy 脚本 / harness / 这里三处都要导出。
JENKINS_AGENT_HOST_KEY ?= $(shell awk 'NR==1{print $$1" "$$2}' secrets/agent_host_key.pub 2>/dev/null)
export JENKINS_AGENT_HOST_KEY

# 镜像只有一个来源：GitHub Actions 构建推进 GHCR，本地只拉不建。
# 默认 1 是为了可复现：任何人 clone 下来都拿到**同一批镜像**。
# 本地构建保留给 Dockerfile 验证（make build-local），产物不推 GHCR。
USE_GHCR ?= 1
ifeq ($(USE_GHCR),1)
COMPOSE += -f docker-compose.yml -f docker-compose.ghcr.yml
COMPOSE_LOCAL = docker compose
else
COMPOSE_LOCAL = $(COMPOSE)
endif

.PHONY: help render deploy up down doctor init hosts ca ca-export render-config \
        jobs jobs-test backup restore backup-verify \
        lint check check-all test test-bats test-groovy \
        images-lock images-pin images-guard build-local hooks identity-check \
        check-jenkins-image check-pins docs-check sbom cve links redaction \
        ldap-passwords ldap-apply ldap-init clean labels-sync

# ---------------------------------------------------------------------------
# 帮助（按操作顺序分组，不按字母排）
# ---------------------------------------------------------------------------
help:
	@echo "第一步：看清楚再动手"
	@echo "  make doctor      只读自检：Docker/端口/配置/磁盘/镜像（不启动任何容器）"
	@echo "  make render      只渲染：config/orgflow.yml -> out/runtime.env + out/Caddyfile + out/dex"
	@echo "  make hosts       生成 /etc/hosts 片段（IP=192.168.0.50 可指定）"
	@echo ""
	@echo "第二步：部署"
	@echo "  make deploy      渲染 → 生成密钥/CA → 按 start_order 串行起 11 个服务 → 三层端点自检"
	@echo "  make deploy SERVICE=ldap   只重建一个服务"
	@echo "  make init        deploy 之后收尾：LDAP 目录初始化 → 推 Job → Nexus（幂等）"
	@echo "  make down        停止并移除容器（不动数据卷）"
	@echo ""
	@echo "第三步：客户端信任"
	@echo "  make ca          把内部 CA 根证书装进本机信任库（config/ca/orgflow-ca.crt）"
	@echo "  make ca-export   只导出 out/ca/root.crt 与安装脚本（不装）"
	@echo ""
	@echo "第四步：验证"
	@echo "  make test        静态 + 行为自检（python，无 docker）"
	@echo "  make test-bats   四层真机行为（DinD，需要 docker，几分钟）"
	@echo "  make check-all   提交前全量门禁（等于 pre-push 跑的那一套）"
	@echo ""
	@echo "运维"
	@echo "  make backup / make restore SERVICE=… BACKUP_FILE=… / make backup-verify"
	@echo "  make sbom / make cve / make links / make redaction / make docs-check"
	@echo "  make images-guard（deploy 前置）/ images-pin / images-lock / build-local"
	@echo "  make hooks（新克隆必做）/ identity-check / labels-sync / clean"
	@echo "  USE_GHCR=0 make deploy 用本地构建镜像（仅本地验证）"

# ---------------------------------------------------------------------------
# 配置与渲染
# ---------------------------------------------------------------------------
render: $(RUNTIME_ENV)
	@echo "已渲染 $(RUNTIME_ENV) + out/Caddyfile + out/dex/config.yaml"

# runtime.env 是产物：compiler 是 scripts/10-render-config.sh，输入是 config/。
# 用文件依赖而不是 phony，改配置就会自动重渲染，没改就不重跑。
$(RUNTIME_ENV): config/orgflow.yml config/services.yml config/routes.yaml scripts/lib/config.py
	@bash scripts/10-render-config.sh

render-config: $(RUNTIME_ENV)

hosts:
	@bash scripts/22-gen-hosts.sh $(IP)

ca: $(RUNTIME_ENV)
	@bash scripts/21-ca-install.sh

ca-export: $(RUNTIME_ENV)
	@bash scripts/21-ca-install.sh --export

# ---------------------------------------------------------------------------
# 部署
# ---------------------------------------------------------------------------
deploy: images-guard $(RUNTIME_ENV)
	@USE_GHCR="$(USE_GHCR)" bash scripts/50-deploy.sh $(if $(SERVICE),--service $(SERVICE),)

up: images-guard $(RUNTIME_ENV)
	$(COMPOSE) --env-file $(RUNTIME_ENV) up -d $(if $(filter 1,$(USE_GHCR)),--no-build)

down:
	$(COMPOSE) --env-file $(RUNTIME_ENV) down

doctor:
	@python3 scripts/16-doctor.py

# 本地构建（显式）：改了 Dockerfile 想立刻验证时用，产物只在本地，**不推 GHCR**。
build-local: $(RUNTIME_ENV)
	@echo "== 本地构建（USE_GHCR=0）：产物不推 GHCR，只供本地验证 =="
	$(COMPOSE_LOCAL) build caddy router dnsmasq jjb jenkins jenkins-agent docs
	@echo "== 完成；用 USE_GHCR=0 make deploy 部署这套本地镜像 =="

# deploy 之后的一键收尾；每步都幂等，失败时能指出卡在哪一步。
init: $(RUNTIME_ENV)
	@bash scripts/51-init.sh

# ---------------------------------------------------------------------------
# Jenkins Job（jjb 走 compose 内网 http://jenkins:8080，不经网关）
# ---------------------------------------------------------------------------
jobs: $(RUNTIME_ENV)
	@bash scripts/13-gen-jjb-conf.sh "$(RUNTIME_ENV)"
	$(COMPOSE) --env-file "$(RUNTIME_ENV)" run --rm jjb jenkins-jobs --conf /repo/.jjb/jenkins_jobs.ini update config/job_definitions/

jobs-test: $(RUNTIME_ENV)
	@bash scripts/13-gen-jjb-conf.sh "$(RUNTIME_ENV)" --placeholder
	$(COMPOSE) run --rm -T jjb jenkins-jobs --conf /repo/.jjb/jenkins_jobs.ini test --config-xml -o /repo/.jjb/rendered config/job_definitions/

# ---------------------------------------------------------------------------
# 备份与恢复
# ---------------------------------------------------------------------------
backup: $(RUNTIME_ENV)
	@bash scripts/61-backup.sh --all

restore: $(RUNTIME_ENV)
	@test -n "$$SERVICE" && test -n "$$BACKUP_FILE" || { echo "必须显式传 SERVICE 和 BACKUP_FILE" >&2; exit 1; }
	@read -r -p "将停服并覆盖 $$SERVICE 数据；输入 YES 继续: " confirm && \
		test "$$confirm" = YES || { echo "未确认，取消恢复" >&2; exit 1; }; \
		bash scripts/62-restore.sh --service "$$SERVICE" --file "$$BACKUP_FILE" --force

backup-verify:
	@test -n "$$BACKUP_FILE" || { echo "必须传 BACKUP_FILE" >&2; exit 1; }
	@bash scripts/61-backup.sh --verify "$$BACKUP_FILE"

restore backup-verify: export SERVICE := $(SERVICE)
restore backup-verify: export BACKUP_FILE := $(BACKUP_FILE)

# ---------------------------------------------------------------------------
# 门禁：check 是 pre-commit 那一层（几秒、无 docker），check-all 是 pre-push 那一层。
# 定义在 scripts/ 里而不是这里，因为钩子不能依赖 make。
# ---------------------------------------------------------------------------
lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh scripts/lib/*.sh .github/scripts/*.sh || echo "shellcheck 未安装，跳过"
	@command -v yamllint >/dev/null && yamllint config services docker-compose.yml || echo "yamllint 未安装，跳过"

check:
	@bash scripts/check-fast.sh

check-all:
	@bash scripts/check-all.sh

test: check-jenkins-image
	@python3 -m py_compile services/router/render.py scripts/lib/config.py
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
	@python3 scripts/test_config.py
	@python3 scripts/migrate_identity.py --verify
	@python3 scripts/test_ldif_passwords.py
	@python3 scripts/test_ldap_set_passwords.py
	@python3 scripts/test_labels.py
	@python3 scripts/check-actions-pinned.py .
	@python3 scripts/test_plugin_licenses.py
	@$(MAKE) --no-print-directory docs-check
	@echo "python syntax ok"

docs-check:
	@python3 scripts/check_docs_meta.py

sbom:
	@python3 scripts/18-gen-sbom.py out/sbom.spdx.json

cve:
	@bash scripts/17-cve-scan.sh

links:
	@python3 scripts/check_export_links.py .

redaction:
	@bash scripts/check-public-redaction.sh .

# 目录初始口令：LDIF 里只有 {SSHA} 哈希，真值是 config/orgflow.yml 的 ldap.password。
# 两处不一致的表现是「账号密码明明对，bind 却返回 49」，所以做成一条命令。
# 注意：这条只重算**仓库里的 LDIF**，对已经存在的目录条目无效 —— 运行中的目录用 make ldap-apply。
ldap-passwords:
	@set -e; \
	pw=$$(python3 -c 'import scripts.lib.config as c; print(c.load()["ldap"]["password"])' 2>/dev/null || \
	     python3 -c 'import sys; sys.path.insert(0,"scripts/lib"); import config; print(config.load()["ldap"]["password"])'); \
	if [ -z "$$pw" ]; then echo "✗ config/orgflow.yml 里没有 ldap.password" >&2; exit 1; fi; \
	ORGFLOW_INITIAL_PASSWORD="$$pw" python3 scripts/11-gen-ldif-passwords.py >/dev/null; \
	echo "✓ users.ldif 的 {SSHA} 已按 config/orgflow.yml 的 ldap.password 重算"
	@echo "  目录已经存在时这一步不会改运行中的口令；要生效再跑 make ldap-apply"

# 把配置里的口令真正设到**运行中的目录**（ldapmodify）。目录建好之后改 LDIF 不生效
# （ldapadd 对已存在的 DN 只报 already exists），这是这套栈最容易踩的误解。
ldap-apply: $(RUNTIME_ENV)
	@bash scripts/11-ldap-set-passwords.sh

# 全新部署最容易漏的两步（bootstrap 空目录 + 口令落运行中的目录）串成一条，均幂等。
ldap-init: $(RUNTIME_ENV)
	@$(COMPOSE) --env-file $(RUNTIME_ENV) exec -T ldap bash /opt/orgflow-auth/bootstrap-ldif.sh
	@$(MAKE) --no-print-directory ldap-apply

labels-sync:
	@python3 scripts/sync-labels.py

# #90 / REQ-M0-B1：Jenkins 镜像静态自检。不构建镜像时容器内插件清单无法实测，
# 用「清单必含项 + Dockerfile 用 jenkins-plugin-cli 安装」替代。
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

# 镜像来源闸门：USE_GHCR=1 时禁止把「源码已改、镜像没重建」的状态部署出去。
# 反证：改一下 services/jenkins/Dockerfile 再跑 make deploy，这条必须红。
images-guard:
	@USE_GHCR="$(USE_GHCR)" bash scripts/check-image-source.sh

# 旧名字保留：外部脚本/文档里还写着 make check-pins
check-pins: images-guard

# test-bats 验证的是「**本次源码**构建出来的栈能不能起来」，所以它必须本地构建。
# 用 GHCR 镜像跑 bats 是自欺：GHCR 上是上一个提交的镜像，PR 改的东西根本不在里面。
TEST_BATS_GHCR ?= 0
ifneq ($(filter test-bats,$(MAKECMDGOALS)),)
ifneq ($(filter environment command line,$(origin USE_GHCR)),)
ifneq ($(USE_GHCR),$(TEST_BATS_GHCR))
$(warning USE_GHCR=$(USE_GHCR) 对 test-bats 无效：bats 只测本地构建。要跑 GHCR 镜像请用 TEST_BATS_GHCR=1)
endif
endif
endif

test-bats: $(RUNTIME_ENV)
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
	@bash scripts/15-pin-images.sh

# 共享库行为测试只依赖 groovy 本身（GroovyShell + metaClass 打桩，无外部 jar）
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
# 只删渲染产物，保留目录本身。
clean:
	@rm -f out/Caddyfile out/Caddyfile.probe out/*.tmp out/runtime.env
	@echo "已清理渲染产物（保留 out/ 目录）"

hooks:
	@git config core.hooksPath .githooks
	@chmod +x .githooks/*
	@echo "已安装钩子：$(shell ls .githooks | tr '\n' ' ')"
	@echo "钩子内容：pre-commit 校验提交身份，pre-push 拦主干 + 校验身份"

# 校验 author 是否唯一（main 上 committer 允许 GitHub 平台）
# --no-merges 必须保留：GitHub 为 PR 生成的合成合并提交 author 是 noreply 邮箱。
# ★ 这条过滤**只管合并提交**。squash 合并的产物只有单父，--no-merges 不生效，
#   author 会被改写成 noreply 而这里照样红——2026-10-31 就这么红过一次（PR #25）。
#   所以合并一律 rebase，见 CONTRIBUTING.md。
identity-check:
	@bad=0; \
	for ae in $$(git log --no-merges --format='%ae' | sort -u); do \
		if [ "$$ae" != "zeek.zhao@foxmail.com" ]; then echo "✗ author 异常: $$ae"; bad=1; fi; \
	done; \
	if [ "$$bad" = 0 ]; then echo "✓ author 唯一: zeek.zhao@foxmail.com"; else exit 1; fi
