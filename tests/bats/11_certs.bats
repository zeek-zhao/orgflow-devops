#!/usr/bin/env bats
# 11_certs —— 证书签发与 SAN（§8.3，独立命名空间卷 orgflow-v2-ca-data）

@test "certs-init exit 0" {
  run docker inspect -f '{{.State.ExitCode}}' "${PFX:-of}-certs-init"
  [ "$output" = "0" ]
}

@test "卷内有 ca.crt / site.crt / site.key" {
  for f in ca.crt site.crt site.key; do
    run docker run --rm -v "${CA_VOL:-orgflow-minimal_ca-data}:/ca" alpine test -f "/ca/$f"
    [ "$status" -eq 0 ]
  done
}

@test "站点证书 SAN 含通配域名" {
  run bash -c "docker run --rm -v '${CA_VOL:-orgflow-minimal_ca-data}:/ca' alpine cat /ca/site.crt | openssl x509 -noout -text | grep -c '\\*\\.${DOM:-org-devops.local}'"
  [ "$output" -ge 1 ]
}
