def loadStep(String name, Map state) {
    def step = new GroovyShell().parse(new File("shared-library/vars/${name}.groovy"))
    step.metaClass.error = { String message -> throw new IllegalArgumentException(message) }
    step.metaClass.echo = { Object message -> state.messages << message.toString() }
    step.metaClass.string = { Map binding -> binding }
    step.metaClass.withEnv = { List values, Closure body ->
        state.environment = values.collect { it.toString() }
        body()
    }
    step.metaClass.withCredentials = { List bindings, Closure body ->
        state.bindings = bindings
        state.inCredentials = true
        try {
            body()
        } finally {
            state.inCredentials = false
        }
    }
    step.metaClass.sh = { String command ->
        assert name == 'restoreService' || state.inCredentials
        assert command.contains('set +x')
        assert !command.contains('test-secret')
        state.commands << command
    }
    return step
}

def newState() {
    [messages: [], commands: [], environment: [], bindings: null, inCredentials: false]
}

def expectFailure(Closure body) {
    try {
        body()
        assert false: 'Expected invalid configuration to fail'
    } catch (IllegalArgumentException expected) {
        assert expected.message
    }
}

def dry = newState()
loadStep('deployService', dry).call(service: 'ldap', dryRun: true)
assert dry.messages.size() == 1
assert dry.messages[0].contains('bash scripts/deploy.sh --service ldap')
assert dry.commands.empty
assert dry.environment.empty
assert dry.bindings == null

def deploy = newState()
loadStep('deployService', deploy).call(
    service: 'jenkins', environment: 'staging', dryRun: false
)
assert deploy.commands.size() == 1
assert deploy.commands[0].contains('bash scripts/deploy.sh --service "$DEPLOY_SERVICE"')
assert deploy.environment.contains('ENV_NAME=staging')
// #46：version 已停用，环境里不该再出现 SERVICE_VERSION
assert !deploy.environment.any { it.startsWith('SERVICE_VERSION=') }
assert deploy.bindings*.credentialsId == [
    'ldap-admin-password', 'oauth2-client-secret', 'oauth2-cookie-secret'
]
assert deploy.bindings*.variable == [
    'LDAP_ADMIN_PASSWORD', 'OAUTH2_CLIENT_SECRET', 'OAUTH2_COOKIE_SECRET'
]

// #46：Nexus 走独立 step —— 它已移出 compose，凭据也只用到 nexus-admin-password
def nexusDry = newState()
loadStep('deployNexus', nexusDry).call(environment: 'dev', dryRun: true)
assert nexusDry.messages.size() == 1
assert nexusDry.messages[0].contains('bash scripts/nexus-deploy.sh')
assert nexusDry.commands.empty
assert nexusDry.bindings == null

def nexus = newState()
loadStep('deployNexus', nexus).call(environment: 'prod', dryRun: false)
assert nexus.commands.size() == 1
assert nexus.commands[0].contains('bash scripts/nexus-deploy.sh')
assert nexus.environment.contains('ENV_NAME=prod')
assert nexus.bindings*.credentialsId == ['nexus-admin-password']
assert nexus.bindings*.variable == ['NEXUS_ADMIN_PASSWORD']

def backup = newState()
loadStep('backupService', backup).call(service: 'all', target: 'local', retentionDays: '0')
assert backup.commands.size() == 1
assert backup.commands[0].contains('bash scripts/backup.sh --service "$BACKUP_SERVICE"')
assert backup.bindings == []
assert backup.environment.contains('BACKUP_RETENTION_DAYS=0')

def restore = newState()
loadStep('restoreService', restore).call(service: 'ldap', confirm: 'YES', backupFile: 'out/backups/ldap-test.tgz')
assert restore.commands.size() == 1
assert restore.commands[0].contains('--file "$file" --force')
assert restore.commands[0].contains('if [ -z "$file" ]')
assert restore.environment.contains('RESTORE_SERVICE=ldap')
assert restore.environment.contains('RESTORE_FILE=out/backups/ldap-test.tgz')
assert restore.bindings == null
[
    [service: 'ldap'],
    [service: 'ldap', confirm: 'yes'],
    [service: 'other', confirm: 'YES'],
    [service: 'ldap', confirm: 'YES', backupFile: '$(echo test-secret).tgz'],
    [service: 'ldap', confirm: 'YES', backupFile: "file'; echo test-secret.tgz"]
].each { cfg ->
    def state = newState()
    expectFailure { loadStep('restoreService', state).call(cfg) }
    assert state.commands.empty
    assert state.environment.empty
    assert state.bindings == null
}

[
    [service: 'ldap; echo test-secret'],
    [service: 'caddy', port: '65536'],
    [service: 'caddy', port: '$(echo test-secret)'],
    [service: 'caddy', domain: 'example.test'],
    [service: 'router', version: 'latest'],
    [service: 'ldap', dryRun: 'true'],
    [service: 'ldap', dryRun: 'false'],
    [service: 'jenkins', version: "tag'; echo test-secret"],
    [service: 'ldap', environment: 'other']
].each { cfg ->
    def state = newState()
    expectFailure { loadStep('deployService', state).call(cfg) }
    assert state.commands.empty
    assert state.bindings == null
}
[
    [service: 'other'],
    [service: 'ldap', target: 'nexus'],
    [service: 'ldap', retentionDays: '-1'],
    [service: 'ldap', retentionDays: '7; echo test-secret']
].each { cfg ->
    def state = newState()
    expectFailure { loadStep('backupService', state).call(cfg) }
    assert state.commands.empty
    assert state.bindings == null
}

// verifyService：部署 → healthy → 备份 → 断言。下游 step 用桩替换，只看调用序列。
def loadVerifyStep(Map state) {
    def step = loadStep('verifyService', state)
    step.metaClass.deployService = { Map cfg -> state.calls << ['deployService', cfg.service, cfg.dryRun] }
    step.metaClass.deployNexus = { Map cfg -> state.calls << ['deployNexus', cfg.dryRun] }
    step.metaClass.backupService = { Map cfg -> state.calls << ['backupService', cfg.service] }
    return step
}

// dryRun：只部署 echo，不备份、不跑断言
def verifyDry = newState(); verifyDry.calls = []
loadVerifyStep(verifyDry).call(service: 'ldap', dryRun: true)
assert verifyDry.messages.any { it.contains('== verify service=ldap') }
assert verifyDry.messages.any { it.contains('DRY_RUN') }
assert verifyDry.calls == [['deployService', 'ldap', true]]
assert verifyDry.commands.empty

// 有真卷的服务（ldap）：部署 + 备份 + 断言三件套
def verifyLdap = newState(); verifyLdap.calls = []
loadVerifyStep(verifyLdap).call(service: 'ldap')
assert verifyLdap.calls[0] == ['deployService', 'ldap', false]
assert verifyLdap.calls[1] == ['backupService', 'ldap']
assert verifyLdap.commands.size() == 1
assert verifyLdap.commands[0].contains('cd out/backups')
assert verifyLdap.commands[0].contains('for suffix in tgz sha256 meta')
assert verifyLdap.commands[0].contains('sha256sum -c')

// 无真卷的服务（caddy）：部署后显式跳过备份，没有断言命令
def verifyCaddy = newState(); verifyCaddy.calls = []
loadVerifyStep(verifyCaddy).call(service: 'caddy')
assert verifyCaddy.calls == [['deployService', 'caddy', false]]
assert verifyCaddy.messages.any { it.contains('SKIP backup') }
assert verifyCaddy.commands.empty

// nexus：部署走 deployNexus（#46），备份/断言照常
def verifyNexus = newState(); verifyNexus.calls = []
loadVerifyStep(verifyNexus).call(service: 'nexus')
assert verifyNexus.calls[0] == ['deployNexus', false]
assert verifyNexus.calls[1] == ['backupService', 'nexus']
assert verifyNexus.commands.size() == 1

[
    [service: 'other'],
    [service: 'ldap; echo test-secret'],
    [service: 'ldap', environment: 'other'],
    [service: 'ldap', dryRun: 'true']
].each { cfg ->
    def state = newState(); state.calls = []
    expectFailure { loadVerifyStep(state).call(cfg) }
    assert state.calls == null || state.calls.empty
    assert state.commands.empty
}

// Compile the actual JJB output, including its resolved braces and checkout syntax.
def loader = new GroovyClassLoader()
loader.parseClass('@interface Library { String value(); }')
['deploy-service', 'backup-service', 'restore-service', 'nexus-deploy',
 'verify-dnsmasq', 'verify-jenkins', 'verify-jenkins-agent', 'verify-caddy',
 'verify-router', 'verify-ldap', 'verify-ldapadmin', 'verify-dex',
 'verify-oauth2-proxy', 'verify-homepage', 'verify-nexus'].each { name ->
    def xmlFile = new File(".jjb/rendered/${name}/config.xml")
    assert xmlFile.exists(): 'Run make jobs-test first'
    def factory = javax.xml.parsers.DocumentBuilderFactory.newInstance()
    def xml = factory.newDocumentBuilder().parse(xmlFile)
    def source = xml.getElementsByTagName('script').item(0).textContent
    assert source.contains('checkout(scm)')
    assert source.contains("credentialsId: 'github-token'")
    assert !source.contains('{{')
    loader.parseClass(source, "${name}.groovy")
}
println 'Shared-library behavior and rendered Pipeline compilation: OK'
