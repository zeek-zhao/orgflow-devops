#!/usr/bin/env bash
set -euo pipefail

LDAP_URI="${LDAP_URI:-ldap://ldap:389}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=devops,dc=com}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,dc=devops,dc=com}"
ldif_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ldif"
dry_run=false

if [[ "${1:-}" == "--dry-run" && $# == 1 ]]; then
    dry_run=true
elif (( $# != 0 )); then
    echo "Usage: $0 [--dry-run]" >&2
    exit 2
fi

run() {
    if "$dry_run"; then
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

if "$dry_run"; then
    password_file='<temporary-password-file>'
    echo '# LDAP_ADMIN_PASSWORD is written to a temporary mode-600 file (not logged).'
else
    : "${LDAP_ADMIN_PASSWORD:?LDAP_ADMIN_PASSWORD must be set}"
    umask 077
    password_file="$(mktemp)"
    trap 'rm -f -- "$password_file"' EXIT
    printf '%s' "$LDAP_ADMIN_PASSWORD" > "$password_file"
fi

ldap_args=(-x -H "$LDAP_URI" -D "$LDAP_ADMIN_DN" -y "$password_file" -o nettimeout=5)

# Fail before importing if the directory, credentials or fixed base DN are invalid.
if "$dry_run"; then
    run ldapsearch "${ldap_args[@]}" -b "$LDAP_BASE_DN" -s base dn
else
    ldapsearch "${ldap_args[@]}" -b "$LDAP_BASE_DN" -s base dn > /dev/null
fi

for name in users departments app; do
    file="$ldif_dir/$name.ldif"
    echo "[bootstrap] $name.ldif"
    if run ldapadd "${ldap_args[@]}" -c -f "$file"; then
        continue
    else
        status=$?
    fi
    # LDAP client/transport errors must not be mistaken for individual entry errors.
    if (( status >= 81 )) || (( status == 49 )); then
        echo "[bootstrap] LDAP connection/bind failed (exit $status); aborting" >&2
        exit "$status"
    fi
    if (( status != 68 )); then
        echo "[bootstrap] WARNING: entry errors in $name.ldif (exit $status); continuing" >&2
        ldapsearch "${ldap_args[@]}" -b "$LDAP_BASE_DN" -s base dn > /dev/null
    fi
done

echo '[bootstrap] Directory entry count:'
if "$dry_run"; then
    run ldapsearch "${ldap_args[@]}" -b "$LDAP_BASE_DN" -s sub '(objectClass=*)' dn
    echo "# Pipe the preceding search to: grep -c '^dn:'"
else
    ldapsearch "${ldap_args[@]}" -b "$LDAP_BASE_DN" -s sub '(objectClass=*)' dn |
        grep -c '^dn:'
fi
