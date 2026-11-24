#!/usr/bin/env bats
# 00_full_stack —— 编排结构与 dry-run 顺序（§8.3，静态可跑，无需 docker）
# 覆盖：无顶层 compose / up.sh --dry-run 顺序=manifest / --only ldap 合法 / 幂等逻辑存在。

@test "顶层 docker-compose.yml 不存在" {
  [ ! -f docker-compose.yml ]
}

@test "up.sh --dry-run 输出顺序 == manifest 顺序" {
  run bash -c "python3.11 -c \"import csv;print(' '.join(r['service'] for r in csv.DictReader(open('services/manifest.tsv',encoding='utf-8-sig'),delimiter='\t')))\""
  local expected="$output"
  run bash -c "JSON=1 DRY_RUN=1 bash up.sh 2>/dev/null | python3.11 -c 'import sys,json;print(\" \".join(json.loads(l)[\"service\"] for l in sys.stdin if l.strip()))'"
  [ "$output" = "$expected" ]
}

@test "up.sh --only ldap 是合法服务（dry-run 只演 1 步）" {
  run bash -c "JSON=1 DRY_RUN=1 bash up.sh --only ldap 2>/dev/null | grep -c '\"service\"'"
  [ "$output" = "1" ]
}

@test "未知服务非零退出" {
  run bash -c "DRY_RUN=1 bash up.sh __nope__ >/dev/null 2>&1"
  [ "$status" -ne 0 ]
}

@test "幂等逻辑：已健康服务 skip（源码含 skip 分支）" {
  run grep -q 'already healthy' up.sh
  [ "$status" -eq 0 ]
}
