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
        assert state.inCredentials
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
    service: 'jenkins', environment: 'staging', version: 'lts-jdk17', dryRun: false
)
assert deploy.commands.size() == 1
assert deploy.commands[0].contains('bash scripts/deploy.sh --service "$DEPLOY_SERVICE"')
assert deploy.environment.contains('ENV_NAME=staging')
assert deploy.environment.contains('SERVICE_VERSION=lts-jdk17')
assert deploy.bindings*.credentialsId == [
    'ldap-admin-password', 'oauth2-client-secret', 'oauth2-cookie-secret'
]
assert deploy.bindings*.variable == [
    'LDAP_ADMIN_PASSWORD', 'OAUTH2_CLIENT_SECRET', 'OAUTH2_COOKIE_SECRET'
]

def backup = newState()
loadStep('backupService', backup).call(service: 'all', target: 'local', retentionDays: '0')
assert backup.commands.size() == 1
assert backup.commands[0].contains('bash scripts/backup.sh --service "$BACKUP_SERVICE"')
assert backup.bindings == []
assert backup.environment.contains('BACKUP_RETENTION_DAYS=0')

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

// Compile the actual JJB output, including its resolved braces and checkout syntax.
def loader = new GroovyClassLoader()
loader.parseClass('@interface Library { String value(); }')
['deploy-service', 'backup-service'].each { name ->
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
