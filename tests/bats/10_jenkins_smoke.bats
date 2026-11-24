#!/usr/bin/env bats
# 10_jenkins_smoke —— Job 冒烟脚本集成用例（可选，依赖网络与口令）。
# 默认 skip：未设 JENKINS_PASS 时只做 dry-run 语法/发现性检查；
# 设了 JENKINS_PASS（或 JENKINS_PASS_FILE）才跑真实冒烟并断言 exit 0。

@test "jenkins-smoke.sh 语法与缺口令保护" {
  run bash -n scripts/jenkins-smoke.sh
  [ "$status" -eq 0 ]
  # 无口令必须 exit 2（不联网、不误触发 Job）
  run env -u JENKINS_PASS -u JENKINS_PASS_FILE bash scripts/jenkins-smoke.sh --dry-run
  [ "$status" -eq 2 ]
}

@test "dry-run 能发现 verify-* Job（口令来自 JENKINS_PASS）" {
  [[ -n "${JENKINS_PASS:-}" || -n "${JENKINS_PASS_FILE:-}" ]] || skip "未设 JENKINS_PASS，跳过"
  run bash scripts/jenkins-smoke.sh --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify-"* ]]
}

@test "真实冒烟全绿（可选，设 RUN_SMOKE=1 启用）" {
  [[ "${RUN_SMOKE:-0}" == "1" ]] || skip "设 RUN_SMOKE=1 才跑真实 Job（会触发构建）"
  [[ -n "${JENKINS_PASS:-}" || -n "${JENKINS_PASS_FILE:-}" ]] || skip "未设 JENKINS_PASS"
  run bash scripts/jenkins-smoke.sh
  [ "$status" -eq 0 ]
}
