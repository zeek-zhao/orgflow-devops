// deployService.groovy —— 参数化部署某服务
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   deployService(service: 'jenkins', environment: 'dev', dryRun: true)
def call(Map cfg = [:]) {
    def service = cfg.service ?: error('deployService: service 必填')
    def environment = cfg.environment ?: 'dev'
    def version = cfg.version ?: ''
    if (cfg.dryRun != null && !(cfg.dryRun instanceof Boolean)) {
        error('deployService: dryRun 必须为 boolean')
    }
    def dryRun = cfg.dryRun == true
    if (!(service in ['jenkins', 'caddy', 'router', 'ldap', 'ldapadmin', 'dex', 'oauth2-proxy', 'nexus'])) {
        error('deployService: 不支持的 service')
    }
    if (!(environment in ['dev', 'staging', 'prod'])) {
        error('deployService: 不支持的 environment')
    }
    if (version && (!(service in ['jenkins', 'nexus']) || !(version ==~ /[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}/))) {
        error('deployService: version 仅支持 Jenkins/Nexus 的合法镜像 tag')
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
        echo "DRY_RUN: ENV_NAME=${environment} SERVICE_VERSION=${version} bash scripts/deploy.sh --service ${service}"
        return
    }

    withEnv(["DEPLOY_SERVICE=${service}", "ENV_NAME=${environment}",
             "SERVICE_VERSION=${version}"]) {
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
