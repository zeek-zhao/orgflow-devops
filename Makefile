# orgflow-devops — M0 最小核心
SHELL := /bin/bash
COMPOSE ?= docker compose
ENV_FILE ?= .env

.PHONY: help render deploy up down jobs backup lint test clean

help:
	@echo "make render   渲染 routes.yaml -> out/Caddyfile"
	@echo "make deploy   起 M0 底座（Jenkins/权限/路由/Caddy/Nexus）"
	@echo "make jobs     推送参数化 deploy/backup Job 到 Jenkins"
	@echo "make backup   触发一次全量备份（本地脚本）"
	@echo "make lint     静态检查（shellcheck/yamllint）"
	@echo "make down     停止并移除容器"

render:
	@mkdir -p out
	@python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile
	@echo "rendered out/Caddyfile"

deploy: render
	@bash scripts/deploy.sh

up:
	$(COMPOSE) --env-file $(ENV_FILE) up -d

down:
	$(COMPOSE) --env-file $(ENV_FILE) down

jobs:
	@bash scripts/deploy.sh --push-jobs

backup:
	@bash scripts/backup.sh --all

lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck 未安装，跳过"
	@command -v yamllint >/dev/null && yamllint config services docker-compose.yml || echo "yamllint 未安装，跳过"

test:
	@python3 -m py_compile services/router/render.py
	@echo "python syntax ok"

clean:
	rm -rf out
