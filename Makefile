# orgflow-minimal-devops —— 最小 DevOps 底座
# 原则：同一个结论必须能用一条命令复现。镜像全部 @sha256 锁定。
SHELL := /bin/bash
COMPOSE ?= docker compose
ENV_FILE ?= config/defaults.env

SERVICES := dnsmasq certs-init caddy ldap ldapadmin homepage router

.PHONY: help render up down status up-% down-% check check-all test verify doctor \
        routes hosts ca ca-rotate record images-hash images-guard quota-guard \
        quota-install quota-cron-install quota-supervisor-install quota-runit-install \
        quota-logrotate-install quota-daemon-install quota-status quota-cleanup-nohup \
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

verify-all: ## 手动一键巡检：按 checks.tsv 串行触发全部子 Job（默认 21 项，排除 heavy），输出每项结果与汇总（不注册 cron）
	@bash scripts/verify-all.sh

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

# ---------- 构建资源配额（M2.5 P0 / m2.5.1 生命周期 / m2.5.3 服务化）----------
# 刷新机制优先顺序（高→低）：systemd-timer → cron → supervisor/runit → nohup。
# 安装任何服务前先清理旧 nohup 进程，禁止两个刷新器并行写同一 latest-of-builder.json。
quota-guard: ## 四项资源铁律：采集宿主全资源 + 容器零限制证据（需 docker，默认 of-builder）
	@bash scripts/quota-guard.sh --container $${CONTAINER:-of-builder} --out artifacts/quota

# 精确清理旧 nohup 守护进程：按 daemon.pid 定位并核对命令行含 quota-guard-loop.sh，
# 绝不 pkill -f quota-guard（会误杀正在跑的手动 quota-guard 调用）。
quota-cleanup-nohup: ## 清理旧 nohup 刷新进程（装服务前必做，避免双写）
	@repo="$$(pwd)"; pidfile="$$repo/artifacts/quota/daemon.pid"; \
	if [ -f "$$pidfile" ]; then \
	  pid="$$(cat "$$pidfile" 2>/dev/null | tr -d '\r\n')"; \
	  if [ -n "$$pid" ] && kill -0 "$$pid" 2>/dev/null && ps -p "$$pid" -o args= 2>/dev/null | grep -qF 'quota-guard-loop.sh'; then \
	    kill "$$pid" 2>/dev/null || true; echo "✓ 已停旧 nohup 刷新进程 PID=$$pid"; \
	  else \
	    echo "  (daemon.pid 中的 PID=$${pid:-空} 非本刷新循环，未杀，避免误杀)"; \
	  fi; \
	fi; \
	# m2.5.5 P0-1：仅在确认全场无存活 loop（instances==0）时才删 pidfile；\
	# 有存活 loop 时保留，避免 cleanup 误删正在心跳续约的 PID 导致自检红。\
	inst="$$(bash "$$repo/scripts/quota-guard-loop.sh" --count-instances 2>/dev/null || echo 0)"; \
	if [ "$$inst" = "0" ]; then \
	  rm -f "$$pidfile"; echo "✓ instances=0，旧 pidfile 已清理；可安全安装新服务"; \
	else \
	  echo "⚠ 仍有 $$inst 个存活 loop，保留 pidfile 不删（避免误删续约中的新 PID）"; \
	fi

# 真机 PID1=systemd：timer 每 5 分钟刷新（loop 由 unit 单次调用，无需常驻）。
quota-install: ## [优先1] 安装 systemd timer 自动刷新（systemd 主机）
	@set -e; \
	if [ ! -d /run/systemd/system ]; then echo "⚠ 当前 PID1 非 systemd，timer 不可用；请用 quota-supervisor/quota-cron/quota-daemon" >&2; exit 3; fi; \
	repo="$$(pwd)"; \
	$(MAKE) -s quota-cleanup-nohup; \
	sed "s#__REPO__#$$repo#g" deploy/systemd/orgflow-quota.service > /etc/systemd/system/orgflow-quota.service; \
	sed "s#__REPO__#$$repo#g" deploy/systemd/orgflow-quota.timer > /etc/systemd/system/orgflow-quota.timer; \
	printf 'systemd-timer\n' > artifacts/quota/mechanism.txt; \
	systemctl daemon-reload; \
	systemctl enable --now orgflow-quota.timer; \
	systemctl status orgflow-quota.timer --no-pager -l | head -8

# m2.5.3 P1-1：cron 按分支选模板——用户 crontab 用 5 字段，/etc/cron.d 用 6 字段（含执行用户）。
# 安装后用 awk 'NF>=6 && $1!="#"' 校验系统级模板，不允许"写了就算装好"。
quota-cron-install: ## [优先2] 安装 cron 刷新（用户 crontab 5 字段 / /etc/cron.d 6 字段）
	@set -e; \
	repo="$$(pwd)"; \
	$(MAKE) -s quota-cleanup-nohup; \
	if command -v crontab >/dev/null 2>&1; then \
	  line="$$(sed "s#__REPO__#$$repo#g" deploy/cron/orgflow-quota.cron)"; \
	  marker="quota-guard-loop.sh --once"; \
	  old="$$(crontab -l 2>/dev/null | grep -v -F "$$marker" || true)"; \
	  { [ -n "$$old" ] && printf '%s\n' "$$old"; printf '%s\n' "$$line"; } | crontab -; \
	  echo "✓ 已装入用户 crontab（5 字段）:"; crontab -l | grep -F 'quota' || true; \
	  printf 'cron\n' > artifacts/quota/mechanism.txt; \
	elif [ -d /etc/cron.d ]; then \
	  sed "s#__REPO__#$$repo#g" deploy/cron/orgflow-quota.cron.d > /etc/cron.d/orgflow-quota; \
	  chmod 0644 /etc/cron.d/orgflow-quota; \
	  awk 'NF>=6 && $1!="#"' /etc/cron.d/orgflow-quota | grep -qF 'quota-guard-loop.sh' \
	    || { echo "✗ /etc/cron.d/orgflow-quota 校验失败（无 ≥6 字段的 quota 行）" >&2; exit 5; }; \
	  echo "✓ 已写入 /etc/cron.d/orgflow-quota（6 字段校验通过）:"; grep -F 'quota' /etc/cron.d/orgflow-quota; \
	  printf 'cron\n' > artifacts/quota/mechanism.txt; \
	else \
	  echo "✗ 无 crontab 命令且无 /etc/cron.d：请用 quota-supervisor/quota-runit/quota-daemon" >&2; exit 3; \
	fi

# m2.5.3 P0-1 / m2.5.4 P1-1：PID1=supervisord 主机注册 [program:orgflow-quota]。
# m2.5.4 P1-1 修安装可移植性：
#   - conf 目录由 scripts/supervisor-conf-dir.sh 严格探测（显式 SUPERVISOR_CONF_DIR →
#     supervisorctl 默认 /etc/supervisor/conf.d → 读 supervisord.conf include → 报错 exit 2），
#     绝不静默落到 /usr/local/share/supervisor（那是沙箱 include，真机写进去=假绿）。
#   - WATCHDOG=1/0 渲染 conf 的 __WATCHDOG_AUTOSTART__：真机默认 0（supervisor 原生 autorestart
#     足够，watchdog 同开会双实例），仅本沙箱 autorestart 失效时显式 WATCHDOG=1。
#   - 装后必须断言服务真的 RUNNING（supervisorctl 或 rpc 的 getAllProcessInfo），失败 exit 2，
#     不许"写了配置就算装好"。
quota-supervisor-install: ## [优先3] 注册 supervisor 服务（SUPERVISOR_CONF_DIR=/WATCHDOG= 可覆盖，装后断言 RUNNING）
	@set -e; \
	repo="$$(pwd)"; \
	$(MAKE) -s quota-cleanup-nohup; \
	watchdog="$${WATCHDOG:-0}"; \
	case "$$watchdog" in 1|true|yes) wd=true ;; *) wd=false ;; esac; \
	conf_dir="$$(bash scripts/supervisor-conf-dir.sh)"; \
	sed -e "s#__REPO__#$$repo#g" -e "s#__WATCHDOG_AUTOSTART__#$$wd#g" deploy/supervisor/orgflow-quota.conf > "$$conf_dir/orgflow-quota.conf"; \
	printf 'supervisor\n' > artifacts/quota/mechanism.txt; \
	echo "✓ 配置已写入 $$conf_dir/orgflow-quota.conf（watchdog autostart=$$wd）"; \
	if command -v supervisorctl >/dev/null 2>&1; then \
	  supervisorctl reread; supervisorctl update; \
	  supervisorctl status orgflow-quota | grep -qE 'RUNNING|STARTING' \
	    || { echo "✗ 装后断言失败：orgflow-quota 非 RUNNING（exit 2）" >&2; exit 2; }; \
	  supervisorctl status orgflow-quota; \
	elif [ -n "$${SUPERVISOR_SOCKET:-}" ]; then \
	  python3 scripts/supervisor-rpc.py reload; \
	  state="$$(SUPERVISOR_SOCKET="$$SUPERVISOR_SOCKET" python3 scripts/supervisor-rpc.py status orgflow-quota | awk '{print $$2}')"; \
	  case "$$state" in RUNNING|STARTING) echo "✓ orgflow-quota state=$$state（rpc RUNNING 断言通过）" ;; \
	    *) echo "✗ 装后断言失败：orgflow-quota state=$${state:-unknown}（exit 2）" >&2; exit 2 ;; esac; \
	else \
	  echo "✗ 无 supervisorctl CLI 且未设 SUPERVISOR_SOCKET，无法做 RUNNING 断言（exit 2）；请在真机执行 supervisorctl reread && supervisorctl update" >&2; exit 2; \
	fi

# m2.5.3 P0-1：其他 PID1（runit）主机，软链 service 目录并 sv up。
quota-runit-install: ## [优先3] 注册为 runit 服务（其他 PID1 主机，自动拉起）
	@set -e; \
	repo="$$(pwd)"; \
	command -v sv >/dev/null 2>&1 || { echo "✗ 无 sv 命令（runit 未安装），请用 quota-supervisor/quota-cron/quota-daemon" >&2; exit 3; }; \
	$(MAKE) -s quota-cleanup-nohup; \
	svdir="$$repo/deploy/runit/orgflow-quota"; \
	sed -i "s#__REPO__#$$repo#g" "$$svdir/run"; \
	ln -sfn "$$svdir" /etc/sv/orgflow-quota; \
	printf 'runit\n' > artifacts/quota/mechanism.txt; \
	sv up orgflow-quota; sleep 2; sv status orgflow-quota

# m2.5.3 P1-2：真机可选 logrotate（默认 loop 脚本已内置 >1MB 自轮转，二选一）。
quota-logrotate-install: ## [可选] 安装 logrotate 配置（默认不用，loop 已自轮转）
	@set -e; \
	repo="$$(pwd)"; \
	[ -d /etc/logrotate.d ] || { echo "✗ 无 /etc/logrotate.d" >&2; exit 3; }; \
	sed "s#__REPO__#$$repo#g" deploy/logrotate/orgflow-quota > /etc/logrotate.d/orgflow-quota; \
	echo "✓ 已装 logrotate 配置；注意：需在 quota-guard-loop.sh 关闭自轮转，避免双份 .1"

# 最后兜底：以上均不可用时用 nohup 常驻循环（需在执行日志写明选择理由）。
quota-daemon-install: ## [最后兜底] nohup 守护循环（仅 systemd/cron/supervisor/runit 均不可用时）
	@set -e; \
	repo="$$(pwd)"; \
	pidfile="$$repo/artifacts/quota/daemon.pid"; \
	if [ -f "$$pidfile" ] && kill -0 "$$(cat "$$pidfile" 2>/dev/null)" 2>/dev/null && ps -p "$$(cat "$$pidfile")" -o args= 2>/dev/null | grep -qF 'quota-guard-loop.sh'; then \
	  echo "⚠ quota-daemon 已在运行（PID=$$(cat "$$pidfile")），拒绝重复安装（避免双写）" >&2; exit 4; \
	fi; \
	$(MAKE) -s quota-cleanup-nohup; \
	printf 'nohup\n' > artifacts/quota/mechanism.txt; \
	nohup bash "$$repo/scripts/quota-guard-loop.sh" >/dev/null 2>&1 & \
	for i in $$(seq 1 20); do [ -f "$$pidfile" ] && break; sleep 0.2; done; \
	echo "✓ quota-daemon 已启动（PID=$$(cat "$$pidfile" 2>/dev/null)）；须在执行日志写明选择理由"

quota-status: ## 查看当前机制 + 证据 ts/age/result（age>10min 非 0 退出）
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

# ---------- M3.0 可靠性与灾备 ----------
backup: ## 备份唯一入口（备份+校验+原子写 status → /data/backups/<UTC>，可用 BACKUP_ROOT 覆盖）
	@bash scripts/backup-run.sh

backup-verify: ## 校验备份（sha256 + 逐卷解包 + 条目数，可指定 BACKUP=...）
	@bash scripts/backup-verify.sh $(if $(BACKUP),$(BACKUP),)

disk-report: ## 磁盘水位 + 可清理镜像/旧构建/artifacts 报告（只读）
	@bash scripts/disk-report.sh

prune-images: ## 清理悬空镜像（保留在用 tag，仅 dangling，人工确认制）
	@bash scripts/prune-images.sh

restore: ## 从备份恢复到指定 project（BACKUP=... PROJECT=... 默认 orgflow-drill）
	@bash scripts/restore.sh

gerrit-reindex: ## 全量重建后重建 Gerrit 索引（匿名卷重建必做，NoteDb 为数据源）
	@bash scripts/gerrit-reindex.sh

# ---------- M3.0.3 手动运维（去所有长定时器；E1/E2）----------
# 备份全部手动：backup/backup-verify/backup-rotate/backup-status 无守护、无 03:30 常驻。
backup-status: ## 只读查看最近一轮备份 status.json（手动）
	@bash scripts/backup-daemon.sh status

backup-once: ## 手动触发一轮备份（补跑/测试，支持 BACKUP_FAKE_NOW）
	@bash scripts/backup-daemon.sh once

drill: ## 前台手动跑隔离恢复演练：输出 DRILL PASS/FAIL，退出码即结果（不注册任何调度）
	@bash scripts/drill-up.sh
