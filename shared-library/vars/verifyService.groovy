// verifyService.groovy —— 单服务自检：部署 → healthy → 备份 → 断言产物
//
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   verifyService(service: 'ldap', environment: 'dev', dryRun: false)
//
// 为什么不并进 deployService：这是「验证」不是「部署」——它串了 deploy 与
// backup 两类操作再加断言，失败语义是「这个服务的日常运维闭环坏没坏」，
// 与单次部署不同。每服务一个 verify-<name> job（JJB 循环生成）都走它。
//
// 健康等待不需要这里做：deploy.sh 的健康闸门（每服务最多 600s）与
// nexus-deploy.sh 的 REST API 等待本身就是步骤的一部分，非零退出即失败。
//
// 备份降级：backup.sh 只支持 jenkins / nexus / ldap 三个有真数据卷的服务，
// 其余服务没有可备份的持久卷，备份阶段显式跳过并 echo 原因——静默跳过
// 会让人误以为备份跑了。
def call(Map cfg = [:]) {
    def service = cfg.service ?: error('verifyService: service 必填')
    def environment = cfg.environment ?: 'dev'
    if (cfg.dryRun != null && !(cfg.dryRun instanceof Boolean)) {
        error('verifyService: dryRun 必须为 boolean')
    }
    def dryRun = cfg.dryRun == true

    // 与 deploy.sh 的 case 白名单 + nexus（走 deployNexus，#46）保持一致。
    // 两边各写一份是因为报错要早：JJB 渲染期不校验 service 名。
    def deployable = ['dnsmasq', 'jenkins', 'jenkins-agent', 'caddy', 'router',
                      'ldap', 'ldapadmin', 'dex', 'oauth2-proxy', 'homepage', 'nexus']
    // 与 backup.sh / backupService 的白名单一致：只有这三个有真卷可备。
    def backupable = ['jenkins', 'nexus', 'ldap']
    if (!(service in deployable)) {
        error("verifyService: 不支持的 service: ${service}")
    }
    if (!(environment in ['dev', 'staging', 'prod'])) {
        error('verifyService: 不支持的 environment')
    }

    echo "== verify service=${service} env=${environment} dryRun=${dryRun} =="

    // 阶段 1：部署（nexus 单独走 deployNexus，见 #46 的说明）
    if (service == 'nexus') {
        deployNexus(environment: environment, dryRun: dryRun)
    } else {
        deployService(service: service, environment: environment, dryRun: dryRun)
    }

    if (dryRun) {
        echo "DRY_RUN: 跳过备份与断言（service=${service}）"
        return
    }

    // 阶段 2：备份（仅限有真卷的服务；无卷服务显式说明并跳过）
    if (!(service in backupable)) {
        echo "SKIP backup: service=${service} 无持久数据卷，backup.sh 不支持"
        return
    }
    backupService(service: service, target: 'local')

    // 阶段 3：断言本次备份产出三件套（归档 / 校验和 / 元数据）。
    // backup.sh 逐份产出 <svc>-<ts>.{tgz,sha256,meta}，三件缺一即坏。
    // 注意：.sha256 清单里是相对 out/backups 的纯文件名（backup-common.sh），
    // 校验必须在该目录内执行。
    withEnv(["VERIFY_SERVICE=${service}"]) {
        withCredentials([]) {
            sh '''
            set +x
            set -eu
            cd out/backups
            latest="$(ls -1t "$VERIFY_SERVICE"-*.tgz 2>/dev/null | head -1 || true)"
            if [ -z "$latest" ]; then
                echo "verifyService: out/backups/ 下没有 $VERIFY_SERVICE 的备份归档" >&2
                exit 1
            fi
            base="${latest%.tgz}"
            for suffix in tgz sha256 meta; do
                test -f "${base}.${suffix}" || {
                    echo "verifyService: 缺少 ${base}.${suffix}" >&2
                    exit 1
                }
            done
            sha256sum -c "${base}.sha256" >/dev/null
            echo "verifyService: $VERIFY_SERVICE 备份三件套齐全且校验通过: ${base}.tgz"
        '''
        }
    }
}
