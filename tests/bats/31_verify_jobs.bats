#!/usr/bin/env bats
# verify-<svc> job 定义的静态一致性（#70 的测试面）。
#
# 为什么只做静态断言、不在 DinD 里真触发 job：
#   1. job 的 checkout(scm) 需要私有仓库凭据（github-token = ${GITHUB_TOKEN}），
#      测试栈必须无凭据（.env.example 的 token 为空），真触发只会死在 checkout；
#   2. Groovy 行为与渲染产物编译由 stepsTest.groovy 覆盖（make test-groovy），
#      JJB 渲染由 make jobs-test 覆盖；
#   3. 这里补的是**跨文件一致性**——三份白名单各写一处，谁改了谁没改，
#      渲染器和编译器都不报错，只有对着源头比才抓得住。
#
# 编号 31：纯静态，不碰栈，位置只求可读。

setup() {
    load 'helpers/common'
    setup_gw
}

@test "verify jobs: 模板覆盖 10 个 compose 服务 + nexus，与 deploy.sh 口径一致" {
    local file="$M0_REPO/config/job_definitions/verify/verify-service.yaml"
    [ -f "$file" ]

    # svc 列表 = compose 全部服务 + nexus（deployNexus 负责，#46），不多不少
    local expected
    expected="$({ compose_cmd config --services; echo nexus; } | sort | tr '\n' ' ')"
    local actual
    actual="$(awk '/^    svc:/{flag=1; next} flag && /^    jobs:/{exit} flag && /^      - /{sub(/^      - /,""); print}' "$file" | sort | tr '\n' ' ')"
    [ "$actual" = "$expected" ]
}

@test "verify jobs: 模板 DSL 引用 verifyService 且带 DRY_RUN 参数" {
    local file="$M0_REPO/config/job_definitions/verify/verify-service.yaml"
    grep -q 'name: verify-{svc}' "$file"
    grep -q "verifyService(" "$file"
    grep -q "service: '{svc}'" "$file"
    grep -q 'name: DRY_RUN' "$file"
    # 与既有 job 同款：固定节点 + 同一 scm 声明（贴 deploy-service 的口径）
    grep -q "node('orgflow-docker')" "$file"
    grep -q 'credentials-id: github-token' "$file"
}

@test "verifyService: deployable 白名单与 deploy.sh 的 case 完全一致" {
    # deploy.sh case 行（去掉空串与 nexus——nexus 走 deployNexus）
    local from_script
    from_script="$(sed -n 's/^  ""|\(.*\)) ;;/\1/p' "$M0_REPO/scripts/deploy.sh" \
        | tr '|' '\n' | grep -vx nexus | sort | tr '\n' ' ')"
    [ -n "$from_script" ]

    local from_step
    from_step="$(grep -A2 'def deployable' "$M0_REPO/shared-library/vars/verifyService.groovy" \
        | grep -oE "'[a-z0-9-]+'" | tr -d "'" | grep -vx nexus | sort | tr '\n' ' ')"
    [ "$from_step" = "$from_script" ]

    # nexus 必须在 deployable 里（走 deployNexus 的那条分支）
    grep -A2 'def deployable' "$M0_REPO/shared-library/vars/verifyService.groovy" | grep -q "'nexus'"
}

@test "verifyService: backupable 白名单与 backupService/backup.sh 一致（仅真卷服务）" {
    local from_backup_step
    from_backup_step="$(grep -oE "\['jenkins', 'nexus', 'ldap'" \
        "$M0_REPO/shared-library/vars/backupService.groovy" | head -1)"
    [ -n "$from_backup_step" ]

    local from_verify_step
    from_verify_step="$(grep -A1 'def backupable' "$M0_REPO/shared-library/vars/verifyService.groovy" \
        | grep -oE "'[a-z0-9-]+'" | tr -d "'" | sort | tr '\n' ' ')"
    [ "$from_verify_step" = "jenkins ldap nexus " ]
}
