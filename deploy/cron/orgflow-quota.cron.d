# OrgFlow 配额证据自动刷新（m2.5.3 P1-1：系统级 /etc/cron.d 用 6 字段，第 6 字段为执行用户 root）
# 用户 crontab 请用 5 字段模板 deploy/cron/orgflow-quota.cron；两者不可混用。
# __REPO__ 由 make quota-cron-install 用 sed 渲染为仓库绝对路径。
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /bin/bash __REPO__/scripts/quota-guard-loop.sh --once >> __REPO__/artifacts/quota/cron.log 2>&1
