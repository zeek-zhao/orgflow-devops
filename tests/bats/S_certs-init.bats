#!/usr/bin/env bats
# S_certs-init —— 首次签发/二次幂等/卷内有 CA+证书/SAN 含通配

@test "首次签发 exit 0" {
  run docker inspect -f '{{.State.ExitCode}}' of-certs-init
  [ "$output" = "0" ]
}

@test "卷内有 CA 与站点证书" {
  run docker run --rm -v orgflow_ca-data:/ca alpine test -f /ca/ca.crt
  [ "$status" -eq 0 ]
  run docker run --rm -v orgflow_ca-data:/ca alpine test -f /ca/site.crt
  [ "$status" -eq 0 ]
}

@test "站点证书 SAN 含通配" {
  run bash -c 'docker run --rm -v orgflow_ca-data:/ca alpine cat /ca/site.crt | openssl x509 -noout -text | grep -c "\\*\\.org-devops.local"'
  [ "$output" -ge 1 ]
}

@test "二次运行幂等跳过" {
  run bash -c 'docker start of-certs-init >/dev/null && docker wait of-certs-init'
  [ "$output" = "0" ]
}
