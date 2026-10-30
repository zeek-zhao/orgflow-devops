// deployService.groovy —— 参数化部署某服务
// 用法（Pipeline）：
//   @Library('orgflow-shared') _
//   deployService(service: 'jenkins', environment: 'dev', version: 'latest', port: '8080', domain: 'devops.internal')
def call(Map cfg = [:]) {
    def service = cfg.service ?: error('deployService: service 必填')
    def environment = cfg.environment ?: 'dev'
    def version = cfg.version ?: 'latest'
    def port = cfg.port ?: ''
    def domain = cfg.domain ?: ''

    echo "== deploy service=${service} env=${environment} version=${version} port=${port} domain=${domain} =="

    dir('orgflow-devops') {
        sh """
            set -e
            export SERVICE_VERSION='${version}'
            export SERVICE_PORT='${port}'
            export SERVICE_DOMAIN='${domain}'
            export ENV_NAME='${environment}'
            docker compose --env-file .env -p orgflow-devops up -d ${service}
            docker compose -p orgflow-devops ps ${service}
        """
    }
}
