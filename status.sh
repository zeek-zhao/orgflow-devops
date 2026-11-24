#!/usr/bin/env bash
# status.sh —— 只读查看各容器健康状态（v1.0 §5.3 配套脚本）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
ORDER=(dnsmasq certs-init ldap caddy homepage ldapadmin router)
JSON=0
[[ "${JSON:-0}" == "1" ]] && JSON=1
for a in "$@"; do [[ "$a" == --json ]] && JSON=1; done

(( JSON )) || printf '%-12s %-12s %s\n' SERVICE STATUS CONTAINER_ID
rc=0
for svc in "${ORDER[@]}"; do
  cid="$(docker ps -aq -f "name=^of-${svc}\$" 2>/dev/null | head -1)"
  if [[ -z "$cid" ]]; then st="absent"; else
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null)"
    [[ "$st" == "exited" ]] && ec="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null)" && st="exited($ec)"
  fi
  if (( JSON )); then
    python3.11 -c "import json;print(json.dumps({'service':'$svc','status':'$st','id':'${cid:0:12}'}))"
  else
    printf '%-12s %-12s %s\n' "$svc" "$st" "${cid:0:12}"
  fi
  case "$st" in healthy|exited\(0\)) ;; *) rc=1 ;; esac
done
exit $rc
