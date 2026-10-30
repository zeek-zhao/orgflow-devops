// backupService.groovy —— 参数化备份某服务
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   backupService(service: 'jenkins', target: 'local', retentionDays: '7')
def call(Map cfg = [:]) {
    def service = cfg.service ?: error('backupService: service 必填')
    def target = cfg.target ?: 'local'
    def retention = cfg.retentionDays ?: '7'
    if (!(service in ['jenkins', 'nexus', 'ldap', 'all'])) {
        error('backupService: 不支持的 service')
    }
    if (target != 'local') {
        error('backupService: M0 仅支持 local 备份目标')
    }
    if (!(retention ==~ /[0-9]{1,5}/)) {
        error('backupService: retentionDays 必须为 0-99999 的整数')
    }

    echo "== backup service=${service} target=${target} retention=${retention}d =="

    withEnv(["BACKUP_SERVICE=${service}", "BACKUP_TARGET=${target}",
             "BACKUP_RETENTION_DAYS=${retention}"]) {
        withCredentials([]) {
            sh '''
                set +x
                set -eu
                bash scripts/backup.sh --service "$BACKUP_SERVICE"
            '''
        }
    }
}
