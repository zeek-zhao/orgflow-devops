#!/usr/bin/env bats
# S_certs-init —— 首次签发 exit 0 / 卷内有 CA+证书 / SAN 含通配 / 二次幂等（§8.1）
# 变量：PFX 容器前缀、CA_VOL 卷名、DOM 域名。runner 注入 ofv2/orgflow-v2-ca-data。

@test "首次签发 exit 0" {
  run docker inspect -f '{{.State.ExitCode}}' "${PFX:-of}-certs-init"
  [ "$output" = "0" ]
}

@test "卷内有 CA 与站点证书" {
  run docker run --rm -v "${CA_VOL:-orgflow-minimal_ca-data}:/ca" alpine test -f /ca/ca.crt
  [ "$status" -eq 0 ]
  run docker run --rm -v "${CA_VOL:-orgflow-minimal_ca-data}:/ca" alpine test -f /ca/site.crt
  [ "$status" -eq 0 ]
}

@test "站点证书 SAN 含通配" {
  run bash -c "docker run --rm -v '${CA_VOL:-orgflow-minimal_ca-data}:/ca' alpine cat /ca/site.crt | openssl x509 -noout -text | grep -c '\\*\\.${DOM:-org-devops.local}'"
  [ "$output" -ge 1 ]
}

@test "二次运行幂等跳过" {
  run bash -c 'docker start '"${PFX:-of}"'-certs-init >/dev/null && docker wait '"${PFX:-of}"'-certs-init'
  [ "$output" = "0" ]
}
