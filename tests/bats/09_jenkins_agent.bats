#!/usr/bin/env bats
# 09_jenkins_agent —— agent 容器健康 / SSH 会话普通用户 / 工具链 / 节点在线 / 22 不发布（M1）
# 变量：PFX 容器前缀。

@test "jenkins-agent 容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-jenkins-agent"
  [ "$output" = "healthy" ]
}

@test "SSH 会话用户是普通用户 jenkins（uid 1000）" {
  run docker exec -u jenkins "${PFX:-of}-jenkins-agent" id -u
  [ "$output" = "1000" ]
}

@test "工具链以 jenkins 身份可用（dig/ldapsearch/curl/java）" {
  run docker exec -u jenkins "${PFX:-of}-jenkins-agent" bash -lc 'dig -v >/dev/null 2>&1 && ldapsearch -VV >/dev/null 2>&1 && curl -V >/dev/null 2>&1 && /opt/java/openjdk/bin/java -version >/dev/null 2>&1 && echo ok'
  [ "$output" = "ok" ]
}

@test "节点 orgflow-agent 在线" {
  PH="$(grep '^PUBLIC_HOST=' config/defaults.env | cut -d= -f2-)"
  PP="$(grep '^PUBLIC_PORT=' config/defaults.env | cut -d= -f2-)"
  run bash -c 'curl -fsS -u "jenkins-ci:Jenkins@2026" -H "Host: '"$PH"'" "http://127.0.0.1:'"${PP:-18081}"'/jenkins/computer/api/json" | python3 -c "import sys,json; d=json.load(sys.stdin); c=[x for x in d[\"computer\"] if x[\"displayName\"]==\"orgflow-agent\"][0]; print(\"offline=\" + str(c[\"offline\"]).lower())"'
  [ "$output" = "offline=false" ]
}

@test "agent 无 docker.sock 挂载" {
  run bash -c '! docker inspect "${PFX:-of}-jenkins-agent" | grep -q "/var/run/docker.sock"'
  [ "$status" -eq 0 ]
}

@test "22 未发布宿主端口" {
  run bash -c '! ss -tln 2>/dev/null | grep -q ":22 "'
  [ "$status" -eq 0 ]
}
