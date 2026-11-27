#!/usr/bin/env python3
# supervisor-rpc.py —— 沙箱/无 supervisorctl CLI 场景用 XML-RPC 管理 supervisord（m2.5.3 P0-1 / m2.5.4 P1-1）
# 真机优先 supervisorctl；本脚本仅在无 CLI 时兜底。socket 必须经 SUPERVISOR_SOCKET 显式传入，
# 不再内置沙箱默认路径（m2.5.4 P1-1：避免把沙箱 socket 当默认值在真机落错地方）。
# 用法：SUPERVISOR_SOCKET=/path/to/supervisor.sock python3 scripts/supervisor-rpc.py <status|reload|start|stop|restart|pid|list> [program]
import socket
import sys
import xmlrpc.client
import os

SOCK = os.environ.get('SUPERVISOR_SOCKET', '')
if not SOCK:
    sys.stderr.write('✗ supervisor-rpc.py: 未设置 SUPERVISOR_SOCKET；请显式指定 supervisor unix socket（真机请用 supervisorctl）\n')
    sys.exit(2)


class UnixTransport(xmlrpc.client.Transport):
    def request(self, host, handler, request_body, verbose=0):
        if isinstance(request_body, str):
            request_body = request_body.encode()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(15)
        s.connect(SOCK)
        req = ("POST %s HTTP/1.0\r\nHost: localhost\r\nContent-Type: text/xml\r\n"
               "Content-Length: %d\r\n\r\n" % (handler, len(request_body))).encode() + request_body
        s.sendall(req)
        buf = b''
        while True:
            d = s.recv(8192)
            if not d:
                break
            buf += d
        s.close()
        _head, _sep, body = buf.partition(b'\r\n\r\n')
        return xmlrpc.client.loads(body)[0]


def call(method, *args):
    p = UnixTransport()
    return p.request('localhost', '/RPC2', xmlrpc.client.dumps(args, method))[0]


def main():
    if len(sys.argv) < 2:
        print('usage: supervisor-rpc.py <status|reload|start|stop|restart|pid|list> [program]')
        sys.exit(2)
    action, prog = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else 'orgflow-quota')
    if action == 'list':
        for x in call('supervisor.getAllProcessInfo'):
            print(x['name'], x['statename'], x['pid'])
        return
    if action == 'reload':
        result = call('supervisor.reloadConfig')
        # XML-RPC 返回 (added, removed, changed) 三元组
        if isinstance(result, (list, tuple)) and len(result) == 3:
            added, removed, changed = result
        else:
            added, removed, changed = [], [], []
        print('reloadConfig added=%s removed=%s changed=%s' % (added, removed, changed))
        for name in added + changed:
            try:
                call('supervisor.addProcessGroup', name)
                print('  addProcessGroup %s ok' % name)
            except xmlrpc.client.Fault as e:
                if 'ALREADY_ADDED' not in str(e):
                    print('  addProcessGroup %s fault: %s' % (name, e))
        return
    if action == 'status':
        info = call('supervisor.getProcessInfo', prog)
        print('%s %s pid=%s' % (info['name'], info['statename'], info['pid']))
        return
    if action == 'pid':
        info = call('supervisor.getProcessInfo', prog)
        print(info['pid'])
        return
    if action == 'start':
        print(call('supervisor.startProcess', prog))
        return
    if action == 'stop':
        print(call('supervisor.stopProcess', prog))
        return
    if action == 'restart':
        try:
            call('supervisor.stopProcess', prog)
        except Exception:
            pass
        print(call('supervisor.startProcess', prog))
        return
    print('unknown action', action)
    sys.exit(2)


if __name__ == '__main__':
    main()
