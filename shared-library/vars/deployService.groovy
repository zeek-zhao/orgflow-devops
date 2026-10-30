// deployService.groovy —— 参数化部署某服务
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   deployService(service: 'jenkins', environment: 'dev', dryRun: true)
def call(Map cfg = [:]) {
    def service = cfg.service ?: error('deployService: service 必填')
    def environment = cfg.environment ?: 'dev'
    def version = cfg.version ?: ''
    def port = cfg.port ?: ''
    def domain = cfg.domain ?: ''
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
    if (port && (service != 'caddy' || !(port ==~ /[0-9]{1,5}/) || port.toInteger() < 1 || port.toInteger() > 65535)) {
        error('deployService: port 仅支持 Caddy 的 1-65535 网关端口')
    }
    if (domain) {
        error('deployService: M0 不支持 DOMAIN 覆盖，请配置 routes/Caddy')
    }

    if (dryRun) {
        echo "DRY_RUN: ENV_NAME=${environment} SERVICE_VERSION=${version} SERVICE_PORT=${port} bash scripts/deploy.sh --service ${service}"
        return
    }

    withEnv(["DEPLOY_SERVICE=${service}", "ENV_NAME=${environment}",
             "SERVICE_VERSION=${version}", "SERVICE_PORT=${port}"]) {
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
