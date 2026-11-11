#!/usr/bin/env bash
# 把 `.env` 的 `ORGFLOW_INITIAL_PASSWORD` 真正设到**运行中的目录**上。
#
# 为什么需要它：`users.ldif` 里只剩 `{SSHA}` 哈希，哈希的真值谁都不知道（这是故意的，
# 公开仓库不能挂一份可用的初始口令）。而目录一旦建好，再改 LDIF 也不会改已有条目 ——
# `ldapadd` 对已存在的 DN 只会报 `already exists`，`bootstrap-ldif.sh` 把它当警告吞掉。
# 于是「.env 里的口令」和「目录里生效的口令」会各说各话：账号密码看着对，simple bind
# 却返回 `Invalid credentials (49)`。CI 上表现为 3 个用例红（jenkins-agent ×2、网关 ACL ×1）。
#
# 所以口令同步只能走 `ldapmodify`：这是唯一能改「已经存在的条目」的路径。
#
# 口令纪律：真值只从 `.env` 读；经 stdin 送进容器，落在容器内 mode-600 的临时文件里，
# 不进 argv、不进宿主环境变量、不打印。`--dry-run` 打印的是把口令替换成 `***` 的负载。
#
# 用法：
#   bash scripts/ldap-set-passwords.sh            # 应用（默认读 .env）
#   bash scripts/ldap-set-passwords.sh --dry-run  # 只打印将执行的 modify 负载与 DN 清单
#   ENV_FILE=/tmp/m0.env bash scripts/ldap-set-passwords.sh
#
# 反证：把 .env 的口令改一个字符后重跑，`ldapwhoami` 那一行会跟着变；
#       不跑本脚本时，`make test-bats` 的 3 个口令相关用例红。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
USERS_LDIF="${USERS_LDIF:-$ROOT/services/auth/ldif/users.ldif}"
SERVICE="${LDAP_SERVICE:-ldap}"
read -r -a COMPOSE_COMMAND <<< "${COMPOSE:-docker compose}"

dry_run=0
case "${1:-}" in
    --dry-run) dry_run=1 ;;
    "") ;;
    *) echo "用法: $0 [--dry-run]" >&2; exit 2 ;;
esac

fail() { echo "✗ $*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || fail "缺少 $ENV_FILE（先跑 make deploy 生成）"
[ -f "$USERS_LDIF" ] || fail "缺少 $USERS_LDIF"

read_env() {
    sed -n "s/^$1=//p" "$ENV_FILE" | tail -1
}

PASSWORD="$(read_env ORGFLOW_INITIAL_PASSWORD)"
[ -n "$PASSWORD" ] || fail "$ENV_FILE 里没有 ORGFLOW_INITIAL_PASSWORD（≥12 字符）"
[ "${#PASSWORD}" -ge 12 ] || fail "ORGFLOW_INITIAL_PASSWORD 至少 12 字符（当前 ${#PASSWORD}）"

LDAP_DOMAIN="$(read_env LDAP_DOMAIN)"
LDAP_DOMAIN="${LDAP_DOMAIN:-devops.com}"
BASE_DN="dc=$(printf '%s' "$LDAP_DOMAIN" | sed 's/\./,dc=/g')"

# 只取用户条目（ou=users 下），分组/应用条目没有口令，不在本脚本范围。
mapfile -t DNS < <(grep -iE '^dn: uid=[^,]+,ou=users,' "$USERS_LDIF" | sed 's/^[Dd][Nn]: *//')
[ "${#DNS[@]}" -gt 0 ] || fail "$USERS_LDIF 里没有 uid=...,ou=users,... 的条目"

build_ldif() {
    local dn
    for dn in "${DNS[@]}"; do
        printf 'dn: %s\n' "$dn"
        printf 'changetype: modify\n'
        printf 'replace: userpassword\n'
        printf 'userpassword: %s\n' "$PASSWORD"
        printf '\n'
    done
}

if (( dry_run )); then
    echo "# 目标: $BASE_DN  账号数: ${#DNS[@]}  口令: ***（来自 $ENV_FILE）"
    for dn in "${DNS[@]}"; do echo "#   $dn"; done
    echo
    build_ldif | sed "s/^userpassword: .*/userpassword: ***/"
    exit 0
fi

# 容器内的执行体：把 stdin 的第一行当口令、其余当 modify 负载，全部落到 mode-600 临时目录。
# 管理口令直接用容器自带的 LDAP_ADMIN_PASSWORD（compose 注入），不经过宿主 argv。
container_script=$(cat <<'CONTAINER'
set -euo pipefail
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
IFS= read -r user_password || true
printf '%s' "$user_password" > "$work/user.pw"
cat > "$work/modify.ldif"
: "${LDAP_ADMIN_PASSWORD:?容器内没有 LDAP_ADMIN_PASSWORD，无法管理目录}"
printf '%s' "$LDAP_ADMIN_PASSWORD" > "$work/admin.pw"
ldapmodify -x -H ldap://localhost:389 -D "cn=admin,$1" -y "$work/admin.pw" -f "$work/modify.ldif" >/dev/null
echo "  ✓ ${2} 个账号已更新口令"
ldapwhoami -x -H ldap://localhost:389 -D "$3" -y "$work/user.pw" >/dev/null
echo "  ✓ 抽检 bind 成功: ${3%%,*}"
CONTAINER
)

COMPOSE_COMMAND+=(--env-file "$ENV_FILE")
if ! "${COMPOSE_COMMAND[@]}" ps --status running -q "$SERVICE" >/dev/null 2>&1 \
   || [ -z "$("${COMPOSE_COMMAND[@]}" ps --status running -q "$SERVICE")" ]; then
    fail "$SERVICE 容器没有运行；先 make deploy（本脚本只改运行中的目录）"
fi

echo "把 $ENV_FILE 的初始口令同步到 ${#DNS[@]} 个账号（$BASE_DN）…"
{
    printf '%s\n' "$PASSWORD"
    build_ldif
} | "${COMPOSE_COMMAND[@]}" exec -T "$SERVICE" bash -c "${container_script[*]}" \
        _ "$BASE_DN" "${#DNS[@]}" "${DNS[0]}"
echo "✓ 完成。现在 LDAP 的初始口令与 $ENV_FILE 一致。"
