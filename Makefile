# orgflow-devops — M0 最小核心
SHELL := /bin/bash
COMPOSE ?= docker compose
ENV_FILE ?= .env

.PHONY: help render deploy doctor up down jobs jobs-test backup lint test test-groovy clean

help:
	@echo "make render   渲染 routes.yaml -> out/Caddyfile"
	@echo "make deploy   起 M0 底座（Jenkins/权限/路由/Caddy/Nexus）"
	@echo "make doctor   只读环境自检（Docker/端口/配置/磁盘/镜像，不启动容器）"
	@echo "make jobs     推送参数化 deploy/backup Job 到 Jenkins"
	@echo "make jobs-test 本地渲染校验 deploy/backup Job（不连接 Jenkins，无需 .env）"
	@echo "make backup   触发一次全量备份（本地脚本）"
	@echo "make lint     静态检查（shellcheck/yamllint）"
	@echo "make test     跑 Python 侧测试（路由/导入/Job 定义）"
	@echo "make test-groovy 跑共享库行为测试（需要 groovy，缺失则跳过）"
	@echo "make down     停止并移除容器"

render:
	@mkdir -p out
	@python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile
	@echo "rendered out/Caddyfile"

deploy: render
	@ENV_FILE="$(ENV_FILE)" COMPOSE="$(COMPOSE)" bash scripts/deploy.sh

doctor:
	@ENV_FILE="$(ENV_FILE)" COMPOSE="$(COMPOSE)" python3 scripts/doctor.py

up:
	$(COMPOSE) --env-file $(ENV_FILE) up -d

down:
	$(COMPOSE) --env-file $(ENV_FILE) down

jobs:
	@bash scripts/gen-jjb-conf.sh "$(ENV_FILE)"
	$(COMPOSE) --env-file "$(ENV_FILE)" run --rm jjb jenkins-jobs --conf /repo/.jjb/jenkins_jobs.ini update config/job_definitions/

jobs-test:
	@bash scripts/gen-jjb-conf.sh "$(ENV_FILE)" --placeholder
	$(COMPOSE) run --rm -T jjb jenkins-jobs --conf /repo/.jjb/jenkins_jobs.ini test --config-xml -o /repo/.jjb/rendered config/job_definitions/

backup:
	@bash scripts/backup.sh --all

lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck 未安装，跳过"
	@command -v yamllint >/dev/null && yamllint config services docker-compose.yml || echo "yamllint 未安装，跳过"

test:
	@python3 -m py_compile services/router/render.py
	@python3 services/router/test_render.py
	@python3 services/auth/test_bootstrap.py
	@python3 scripts/test_deploy.py
	@python3 scripts/test_jobs.py
	@echo "python syntax ok"

# 共享库行为测试只依赖 groovy 本身（用 GroovyShell + metaClass 打桩，无外部 jar）
test-groovy:
	@if command -v groovy >/dev/null 2>&1; then \
		groovy shared-library/test/stepsTest.groovy; \
	else \
		echo "groovy 未安装，跳过（Ubuntu: apt install groovy）"; \
	fi

clean:
	rm -rf out
