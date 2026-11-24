// 服务清单与探测类型（M1，可选）。
// Jenkins 的 load 在 agent 侧对绝对路径支持不稳定且受 Script Security 沙箱约束，
// 故 Jenkinsfile 一律用纯 shell 调 check-lan.sh，不依赖本文件。
// 此处仅作为"服务矩阵"的文档化真源，供人工核对 7+2 个探测目标。
return [
    dns:          [probe: 'dig',        expect: '192.168.90.10'],
    ldap:         [probe: 'ldapsearch', expect: 'dn:'],
    caddy:        [probe: 'curl',       expect: 'HTTP 200 /config/'],
    homepage:     [probe: 'curl',       expect: 'HTTP 200 /'],
    ldapadmin:    [probe: 'curl',       expect: 'HTTP 200 /'],
    router:       [probe: 'curl',       expect: 'ok /healthz'],
    jenkins:      [probe: 'curl',       expect: 'HTTP 200 /jenkins/login'],
    'jenkins-agent': [probe: 'identity', expect: 'uid=1000 + java + dig'],
]
