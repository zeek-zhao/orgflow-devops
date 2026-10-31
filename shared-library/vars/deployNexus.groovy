// deployNexus.groovy —— 部署（或复用）Nexus 制品库（#46）
//
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   deployNexus(environment: 'dev', dryRun: false)
//
// 为什么单独一个 step，而不是并进 deployService：
//   Nexus 不在 docker-compose.yml 里了。`deployService` 走的是
//   `deploy.sh --service <名字>` → `compose up`，这条路对 nexus 已经不成立；
//   它现在由 scripts/nexus-deploy.sh 用 docker run 拉起并改密。
//   两者的失败模式、幂等语义、凭据都不一样，硬塞进一个 step 只会让两边都难读。
def call(Map cfg = [:]) {
    def environment = cfg.environment ?: 'dev'
    if (!(environment in ['dev', 'staging', 'prod'])) {
        error('deployNexus: 不支持的 environment')
    }
    if (cfg.dryRun != null && !(cfg.dryRun instanceof Boolean)) {
        error('deployNexus: dryRun 必须为 boolean')
    }
    def dryRun = cfg.dryRun == true

    if (dryRun) {
        echo "DRY_RUN: ENV_NAME=${environment} bash scripts/nexus-deploy.sh"
        return
    }

    withEnv(["ENV_NAME=${environment}"]) {
        // 密码走凭据注入，不进参数、不进命令行：`set +x` 之外，
        // 用 credentials binding 还能让 Jenkins 在日志里自动打码。
        withCredentials([
            string(credentialsId: 'nexus-admin-password', variable: 'NEXUS_ADMIN_PASSWORD')
        ]) {
            sh '''
                set +x
                set -eu
                bash scripts/nexus-deploy.sh
            '''
        }
    }
}
