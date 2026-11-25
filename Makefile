# orgflow-minimal-devops —— 最小 DevOps 底座
# 原则：同一个结论必须能用一条命令复现。镜像全部 @sha256 锁定。
SHELL := /bin/bash
COMPOSE ?= docker compose
ENV_FILE ?= config/defaults.env

SERVICES := dnsmasq certs-init caddy ldap ldapadmin homepage router

.PHONY: help render up down status up-% down-% check check-all test verify doctor \
        routes hosts ca ca-rotate record images-hash images-guard \
        test-svc-% sync-context images-upstream e2e e2e-up e2e-down e2e-test

# ---------- 帮助 ----------
help: ## 列出全部目标
	@grep -E '^[a-zA-Z0-9_%-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  %-18s %s\n", $$1, $$2}'

# ---------- 配置 ----------
render: ## 渲染配置产物（含 HomePage services.yaml、urls.env；非敏感值来自 defaults.env）
	@mkdir -p out && bash scripts/render.sh
	@python3.11 scripts/render-homepage.py
	@bash scripts/render-urls.sh

# ---------- 部署 ----------
up: images-guard ## 按顺序起全栈（up.sh 五段输出/就绪断言/失败中止）
	@bash up.sh

down: ## 停止并移除全部容器（不动数据卷）
	@bash down.sh

status: ## 只读查看各容器健康状态（STATUS=1 机读）
	@bash status.sh

up-%: ## 只起单个服务（隔离端口，零依赖可起）：make up-dnsmasq
	@bash up.sh --only $*

down-%: ## 只停单个服务：make down-dnsmasq
	@docker compose --env-file $(ENV_FILE) -p orgflow-$* -f services/$*/compose.yml down

test-%: ## 单服务自测：make test-dnsmasq（S_<svc> 行为用例）
	@bash scripts/test-svc.sh $*

# ---------- 门禁与验证 ----------
check: ## 快检查（无 docker）：文档/记录/标签/门禁格式
	@bash scripts/check-fast.sh

check-all: check ## 全量门禁（含镜像 digest 与基底）
	@bash scripts/check-images.sh --mode=lock

test: ## 静态自检（python 语法 + 配置解析）
	@bash scripts/test-static.sh

smoke: ## Jenkins Job 冒烟（触发 verify-* → 等结果 → 下载 consoleText；口令走 JENKINS_PASS）
	@bash scripts/jenkins-smoke.sh $(ARGS)

verify: ## 全量验收矩阵（AC-1~AC-15）
	@bash scripts/verify.sh

# ---------- §8 独立命名空间测试（ofv2，与线上隔离）----------
e2e: ## 独立命名空间测试：起栈 + 跑 bats（线上零影响）
	@bash tests/run-v2.sh up && bash tests/run-v2.sh test
e2e-up: ## 只在独立命名空间起 ofv2 栈（不动线上 of-*）
	@bash tests/run-v2.sh up
e2e-down: ## 只移除 ofv2 容器（保留卷，线上零影响）
	@bash tests/run-v2.sh down
e2e-test: ## 跑全栈+单服务 bats（需先 e2e-up 且已装 bats）
	@bash tests/run-v2.sh test

doctor: ## 只读环境自检（不改状态）
	@bash scripts/doctor.sh

# ---------- 运维 ----------
routes: ## 渲染 routes.yaml → Caddyfile 并 reload
	@bash scripts/render-routes.sh

hosts: ## 生成域名 hosts 片段
	@bash scripts/gen-hosts.sh

ca: ## 导出根证书供客户端安装
	@bash scripts/gen-ca.sh --export

ca-rotate: ## 轮换内部 CA（FORCE 重签）
	@FORCE=1 bash scripts/gen-ca.sh

record: ## 记录一条操作（见 scripts/record.sh --help）
	@bash scripts/record.sh $(ARGS)

# ---------- 镜像 ----------
images-guard: ## 镜像标识闸门：内容哈希与 lock/compose tag 漂移则拒绝部署（r5）
	@bash scripts/check-images.sh --mode=lock

images-hash: ## 计算 M1 内容哈希并校验 lock/compose tag 是否同步（r5 替代 images-lock）
	@bash scripts/image-hash.sh jenkins
	@bash scripts/image-hash.sh jenkins-agent
	@echo "—— 将上面 64hex 前 12 位写入 tests/images.lock contextSha256/tag 与两个 compose 的 ctx- tag"
	@bash scripts/check-images.sh --mode=lock

sync-context: ## 把 config/ 真源同步到各服务的自包含构建上下文 build/
	@bash scripts/sync-build-context.sh

images-upstream: ## 校验 Dockerfile FROM 与上游 digest 登记表一致
	@bash scripts/check-images.sh --mode=upstream
