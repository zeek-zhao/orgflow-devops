// deployService.groovy —— 参数化部署某服务
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   deployService(service: 'jenkins', environment: 'dev', dryRun: true)
def call(Map cfg = [:]) {
    def service = cfg.service ?: error('deployService: service 必填')
    def environment = cfg.environment ?: 'dev'
    if (cfg.dryRun != null && !(cfg.dryRun instanceof Boolean)) {
        error('deployService: dryRun 必须为 boolean')
    }
    def dryRun = cfg.dryRun == true
    // nexus 不在这个列表里（#46）：它已移出 compose，走 deployNexus / nexus-deploy.sh。
    // 白名单与 scripts/deploy.sh 的 case 保持一致（原为 7 个，verify-<svc> job
    // 需要能部署全部 compose 服务，故对齐为 10 个）。
    if (!(service in ['dnsmasq', 'jenkins', 'jenkins-agent', 'caddy', 'router',
                      'ldap', 'ldapadmin', 'dex', 'oauth2-proxy', 'homepage'])) {
        error('deployService: 不支持的 service')
    }
    if (!(environment in ['dev', 'staging', 'prod'])) {
        error('deployService: 不支持的 environment')
    }
    // version 已停用：唯一支持版本覆盖的 nexus 移出了 compose，
    // scripts/deploy.sh 现在对 SERVICE_VERSION 直接报错。传了必须失败，
    // 否则调用方以为自己换了版本，实际什么都没发生。
    if (cfg.version) {
        error('deployService: version 已停用（#46），镜像版本由 compose / .ghcr.yml 的 digest 决定')
    }
    // ADR-13 起网关端口与域名不再由部署参数注入：它们来自环境文件，
    // 由 scripts/deploy.sh 从 compose 解析后渲染。传旧参数必须报错，
    // 否则调用方以为自己改了端口，实际什么都没发生。
    if (cfg.port) {
        error('deployService: port 已废弃（ADR-13 域名路由），请在环境文件设置 GATEWAY_HTTP_PORT / GATEWAY_HTTPS_PORT')
    }
    if (cfg.domain) {
        error('deployService: domain 已废弃（ADR-13 域名路由），请在环境文件设置 GATEWAY_DOMAIN')
    }

    if (dryRun) {
        echo "DRY_RUN: ENV_NAME=${environment} bash scripts/deploy.sh --service ${service}"
        return
    }

    // envFile 可选：agent 工作区没有 .env（verify-<svc> 从 secret file 凭据
    // 注入后传进来）；不传保持原行为（仓库根 .env / .env.<env>）。
    def envValues = ["DEPLOY_SERVICE=${service}", "ENV_NAME=${environment}"]
    if (cfg.envFile) {
        envValues << "ENV_FILE=${cfg.envFile}"
    }
    withEnv(envValues) {
        withCredentials([
            string(credentialsId: 'ldap-admin-password', variable: 'LDAP_ADMIN_PASSWORD'),
            string(credentialsId: 'oauth2-client-secret', variable: 'OAUTH2_CLIENT_SECRET'),
            string(credentialsId: 'oauth2-cookie-secret', variable: 'OAUTH2_COOKIE_SECRET')
        ]) {
            sh '''
                set +x
                set -eu
                bash scripts/deploy.sh --service "$DEPLOY_SERVICE"
            '''
        }
    }
}
