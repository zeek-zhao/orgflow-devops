#!/usr/bin/env bats
# 08_jenkins —— Jenkins controller：容器健康 / 登录页 200 / LDAP 登录 / Job 全绿 / 8080 不发布（M1）
# 变量：PFX 容器前缀、P_PUBLIC 公网入口宿主端口（默认 18081）、PH 公网 Host。

@test "jenkins 容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-jenkins"
  [ "$output" = "healthy" ]
}

@test "登录页 /jenkins/login 200" {
  PH="$(grep '^PUBLIC_HOST=' config/defaults.env | cut -d= -f2-)"
  PP="$(grep '^PUBLIC_PORT=' config/defaults.env | cut -d= -f2-)"
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: $PH" "http://127.0.0.1:${PP:-18081}/jenkins/login"
  [ "$output" = "200" ]
}

@test "/jenkins 无斜杠 308 到 /jenkins/" {
  PH="$(grep '^PUBLIC_HOST=' config/defaults.env | cut -d= -f2-)"
  PP="$(grep '^PUBLIC_PORT=' config/defaults.env | cut -d= -f2-)"
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: $PH" "http://127.0.0.1:${PP:-18081}/jenkins"
  [ "$output" = "308" ]
}

@test "LDAP 账号 jenkins-ci 可登录" {
  PH="$(grep '^PUBLIC_HOST=' config/defaults.env | cut -d= -f2-)"
  PP="$(grep '^PUBLIC_PORT=' config/defaults.env | cut -d= -f2-)"
  run curl -s -o /dev/null -w '%{http_code}' -u "jenkins-ci:Jenkins@2026" -H "Host: $PH" "http://127.0.0.1:${PP:-18081}/jenkins/api/json"
  [ "$output" = "200" ]
}

@test "匿名不可读 Job API（未登录 403/重定向登录）" {
  PH="$(grep '^PUBLIC_HOST=' config/defaults.env | cut -d= -f2-)"
  PP="$(grep '^PUBLIC_PORT=' config/defaults.env | cut -d= -f2-)"
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: $PH" "http://127.0.0.1:${PP:-18081}/jenkins/api/json"
  [[ "$output" == "403" || "$output" == "302" ]]
}

@test "Job 全绿（verify-lan-all 与 7 条子 Job）" {
  PH="$(grep '^PUBLIC_HOST=' config/defaults.env | cut -d= -f2-)"
  PP="$(grep '^PUBLIC_PORT=' config/defaults.env | cut -d= -f2-)"
  run bash -c 'curl -fsS -u "jenkins-ci:Jenkins@2026" -H "Host: '"$PH"'" "http://127.0.0.1:'"${PP:-18081}"'/jenkins/api/json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([j for j in d[\"jobs\"] if j[\"name\"].startswith(\"verify-\")]))"'
  [ "$output" -ge 9 ]
}

@test "8080 未发布宿主端口" {
  run bash -c '! ss -tln 2>/dev/null | grep -q ":8080 "'
  [ "$status" -eq 0 ]
}
