#!/usr/bin/env bash
# 镜像准备与 digest 回写。
#
# GHCR 上的 12 个包全部 public：USE_GHCR=1 的拉取走匿名，不需要 docker login，
# 也不需要任何 PAT（凭据只用在推送侧的工作流里）。
set -euo pipefail
cd "$(dirname "$0")/.."

ghcr_config() {
    docker compose -f docker-compose.yml -f docker-compose.ghcr.yml config --format json
}

harness_image() {
    if [[ ${USE_GHCR:-0} == 1 ]]; then
        ghcr_config | python3 -c '
import json, re, sys
image = json.load(sys.stdin).get("x-m0-test-image", "")
if not re.fullmatch(r"ghcr.io/[^@\s]+@sha256:[a-f0-9]{64}", image):
    sys.exit("Missing pinned GHCR harness; 先跑 images.yml 工作流，再执行 make images-pin")
print(image)
'
    else
        echo orgflow/m0-test:24.04-v1
    fi
}

case "${1:-}" in
    harness-image)
        harness_image
        ;;
    ensure)
        if [[ ${USE_GHCR:-0} == 1 ]]; then
            harness=$(harness_image)
            images=$(ghcr_config | python3 -c '
import json, re, sys
services = json.load(sys.stdin)["services"]
for name, service in services.items():
    image = service.get("image", "")
    if not re.fullmatch(r"ghcr.io/[^@\s]+@sha256:[a-f0-9]{64}", image):
        sys.exit(f"{name}: missing pinned GHCR image; 先跑 images.yml 工作流，再执行 make images-pin")
    print(image)
')
            while read -r image; do
                docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
            done <<< "$images"$'\n'"$harness"
            exit 0
        fi
        while IFS=$'\t' read -r name ref digest; do
            [[ -z $name || $name == \#* ]] && continue
            image="$ref@$digest"
            if docker image inspect "$image" >/dev/null 2>&1; then continue; fi
            case "$ref" in
                ghcr.io/*|quay.io/*)
                    docker pull "$image"
                    ;;
                *)
                    if [[ ${ALLOW_PULL_DOCKER_HUB:-0} == 1 ]]; then
                        # Hosted CI runners start without cached Hub images.
                        docker pull "$image"
                    else
                        # 213 cannot reach Hub; fail fast rather than hang on a pull.
                        echo "Missing local image $image; Docker Hub is unavailable. Import this exact image from a trusted offline source." >&2
                        exit 1
                    fi
                    ;;
            esac
        done < tests/images.lock
        # Rebuild against the current sources (cached when unchanged).
        # jenkins 也在这里构建：底座在 Docker Hub，所以这条路径只适用于能出网的机器；
        # 213 拉不到 Hub，一律走 USE_GHCR=1，不经过这里。
        docker compose build router dnsmasq jenkins
        ;;
    update)
        temporary=$(mktemp tests/images.lock.XXXXXX)
        trap 'rm -f "$temporary"' EXIT
        printf '# logical name<TAB>reference<TAB>digest; update with make images-lock\n' > "$temporary"
        while IFS=$'\t' read -r name ref old_digest; do
            [[ -z $name || $name == \#* ]] && continue
            repository=${ref%:*}
            actual=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$ref")
            digest=$(awk -v prefix="$repository@" 'index($0, prefix) == 1 {sub(/^.*@/, ""); print}' <<< "$actual")
            if [[ ! $digest =~ ^sha256:[a-f0-9]{64}$ ]]; then
                echo "$ref: missing or ambiguous local repository digest" >&2
                exit 1
            fi
            printf '%s\t%s\t%s\n' "$name" "$ref" "$digest" >> "$temporary"
        done < tests/images.lock
        chmod 644 "$temporary"
        mv "$temporary" tests/images.lock
        echo "Updated tests/images.lock; synchronize Compose and Dockerfile references before testing."
        ;;
    *) echo "Usage: bash tests/images.sh ensure|update|harness-image" >&2; exit 2 ;;
esac
