# orgflow-minimal-devops —— 最小 DevOps 底座
# 原则：同一个结论必须能用一条命令复现。镜像全部 @sha256 锁定。
SHELL := /bin/bash
COMPOSE ?= docker compose
ENV_FILE ?= config/defaults.env

SERVICES := dnsmasq certs-init caddy ldap ldapadmin homepage router

.PHONY: help render up down status up-% down-% check check-all test verify doctor \
        routes hosts ca ca-rotate record images-hash images-guard quota-guard \
        quota-cron-install quota-daemon-install quota-install quota-status \
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

# ---------- 构建资源配额（M2.5 P0 / m2.5.1 生命周期）----------
quota-guard: ## 四项资源铁律：采集宿主全资源 + 容器零限制证据（需 docker，默认 of-builder）
	@bash scripts/quota-guard.sh --container $${CONTAINER:-of-builder} --out artifacts/quota

# 真机部署：安装 systemd timer 每 5 分钟自动刷新证据（沙箱 PID1=supervisord，无 systemd 时给出提示）。
# __REPO__ 占位符替换为仓库绝对路径，不硬编码部署机路径。
quota-install: ## 安装并启用配额证据自动刷新 timer（systemd 主机）
	@set -e; \
	if [ ! -d /run/systemd/system ]; then echo "⚠ 当前 PID1 非 systemd，timer 不可用；请在真机执行 make quota-install" >&2; exit 3; fi; \
	repo="$$(pwd)"; \
	sed "s#__REPO__#$$repo#g" deploy/systemd/orgflow-quota.service > /etc/systemd/system/orgflow-quota.service; \
	sed "s#__REPO__#$$repo#g" deploy/systemd/orgflow-quota.timer > /etc/systemd/system/orgflow-quota.timer; \
	systemctl daemon-reload; \
	systemctl enable --now orgflow-quota.timer; \
	systemctl status orgflow-quota.timer --no-pager -l | head -8

# m2.5.2：cron 兜底。优先当前用户 crontab（command -v crontab）；若无 crontab 命令但
# cron daemon 在跑（如本沙箱 runit 管理的 /usr/sbin/cron），退而写入 /etc/cron.d/orgflow-quota。
# 两种路径都先按标记 grep 去重，避免重复行；渲染 __REPO__ 为实际 pwd，不硬编码路径。
quota-cron-install: ## 安装 cron 兜底（每5分钟刷新证据）：优先用户 crontab，缺失时写 /etc/cron.d
	@set -e; \
	repo="$$(pwd)"; \
	line="$$(sed "s#__REPO__#$$repo#g" deploy/cron/orgflow-quota.cron)"; \
	marker="quota-guard.sh --container of-builder"; \
	if command -v crontab >/dev/null 2>&1; then \
	  old="$$(crontab -l 2>/dev/null | grep -v -F "$$marker" || true)"; \
	  { [ -n "$$old" ] && printf '%s\n' "$$old"; printf '%s\n' "$$line"; } | crontab -; \
	  echo "✓ 已装入当前用户 crontab（去重后）:"; crontab -l | grep -F 'quota' || true; \
	elif [ -d /etc/cron.d ]; then \
	  printf '# OrgFlow 配额证据自动刷新（m2.5.2 cron 兜底；由 make quota-cron-install 生成）\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s\n' "$$line" > /etc/cron.d/orgflow-quota; \
	  chmod 0644 /etc/cron.d/orgflow-quota; \
	  echo "✓ crontab 命令不可用，已写入 /etc/cron.d/orgflow-quota:"; grep -F 'quota' /etc/cron.d/orgflow-quota || true; \
	else \
	  echo "✗ 无 crontab 命令且无 /etc/cron.d：请用 make quota-daemon-install" >&2; exit 3; \
	fi

# 最后兜底：连 cron 也没有时，用 nohup 循环每 5 分钟刷新（仅当 cron 不可用才用，需写执行日志说明）。
quota-daemon-install: ## 最后兜底：nohup 守护循环每5分钟刷新（仅 cron/systemd 均不可用时用）
	@set -e; \
	repo="$$(pwd)"; \
	pidfile="$$repo/artifacts/quota/daemon.pid"; \
	if [ -f "$$pidfile" ] && kill -0 "$$(cat "$$pidfile" 2>/dev/null)" 2>/dev/null; then \
	  echo "⚠ quota-daemon 已在运行（PID=$$(cat "$$pidfile")），拒绝重复安装（避免双写）" >&2; exit 4; \
	fi; \
	nohup bash -c 'while true; do bash "'"$$repo"'/scripts/quota-guard.sh" --container of-builder --out "'"$$repo"'/artifacts/quota" >> "'"$$repo"'/artifacts/quota/cron.log" 2>&1; sleep 300; done' >/dev/null 2>&1 & \
	echo $$! > "$$pidfile"; \
	echo "✓ quota-daemon 已启动（PID=$$!，pidfile=$$pidfile）；须在执行日志写明选择理由"

quota-status: ## 查看 timer/cron 状态 + 证据 ts/age（age>10min 非 0 退出）
	@bash scripts/quota-status.sh

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
