#!/usr/bin/env python3.11
# supervisor-rpc.py —— 无 supervisorctl CLI 时，用 XML-RPC 管理 supervisord（m2.5.3 P0-1）
# 本沙箱 PID1=supervisord 但未安装 supervisorctl CLI，unix socket 可用，故用标准库 XML-RPC 调用。
# 用法：python3 scripts/supervisor-rpc.py <status|reload|start|stop|restart|pid> [program]
import socket
import sys
import xmlrpc.client
import os

SOCK = os.environ.get('SUPERVISOR_SOCKET', '/.PlnPyKFp4CRfFtgC1_run/cs-supervisor.sock')


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
