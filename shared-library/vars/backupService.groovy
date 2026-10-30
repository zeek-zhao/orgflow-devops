// backupService.groovy —— 参数化备份某服务
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   backupService(service: 'jenkins', target: 'local', retentionDays: '7')
def call(Map cfg = [:]) {
    def service = cfg.service ?: error('backupService: service 必填')
    def target = cfg.target ?: 'local'
    def retention = cfg.retentionDays ?: '7'

    echo "== backup service=${service} target=${target} retention=${retention}d =="

    dir('orgflow-devops') {
        sh """
            set -e
            export BACKUP_TARGET='${target}'
            export BACKUP_RETENTION_DAYS='${retention}'
            bash scripts/backup.sh --service ${service}
        """
    }
}
