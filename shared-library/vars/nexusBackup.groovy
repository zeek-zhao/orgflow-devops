// nexusBackup.groovy —— Nexus 备份 + 内容校验 + 恢复演练（#93 / REQ-M0-B5）
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   nexusBackup(retentionDays: '7', restoreDrill: true, bootCheck: true)
//
// 与 backupService 的分工：
//   * backupService 只做「停写 → 整卷 tar → sha256」，对任何服务都一样；
//   * Nexus 的数据分 db/ 与 blobs/ 两处，只 tar 出整卷**不能**证明恢复得回来，
//     所以这里额外做内容校验（check_nexus_archive.py）与恢复演练（独立 drill 卷）。
// 另外 Nexus 在 #46 之后移出 compose，停写/启回要按容器名走 docker ——
// backup-common.sh 里已按服务分派，这里不需要知道细节。
def call(Map cfg = [:]) {
    def retention = cfg.retentionDays ?: '7'
    def drill = (cfg.restoreDrill == null) ? true : cfg.restoreDrill
    def boot = (cfg.bootCheck == null) ? true : cfg.bootCheck
    if (!(retention ==~ /[0-9]{1,5}/)) {
        error('nexusBackup: retentionDays 必须为 0-99999 的整数')
    }
    if (!drill) {
        // 没解包就没有可启动的东西，boot check 无意义
        boot = false
    }

    def args = "--retention ${retention}"
    if (!drill) {
        args += ' --no-restore-drill'
    } else if (!boot) {
        args += ' --no-boot-check'
    }

    echo "== nexus backup retention=${retention}d drill=${drill} boot=${boot} =="
    // set +x：脚本会打印备份路径与 sha256，但不要回显任何凭据
    sh "set +x; set -eu; bash scripts/nexus-backup.sh ${args}"
}
