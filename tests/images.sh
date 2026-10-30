#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    ensure)
        while IFS=$'\t' read -r name ref digest; do
            [[ -z $name || $name == \#* ]] && continue
            image="$ref@$digest"
            if docker image inspect "$image" >/dev/null 2>&1; then continue; fi
            case "$ref" in
                ghcr.io/*|quay.io/*)
                    docker pull "$image"
                    ;;
                *)
                    echo "Missing local image $image; Docker Hub is unavailable. Import this exact image from a trusted offline source." >&2
                    exit 1
                    ;;
            esac
        done < tests/images.lock
        # Rebuild against the current sources (cached when unchanged).
        docker compose build router
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
    *) echo "Usage: bash tests/images.sh ensure|update" >&2; exit 2 ;;
esac
