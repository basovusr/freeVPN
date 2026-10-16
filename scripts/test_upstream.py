#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_upstream.py —— 用于验证 mihomo 链路的最小上游代理（本地正向代理）

作用：
  它扮演「你的真实上游节点」的角色。把它配置成 mihomo 的一个 socks5/http 节点后，
  就能验证完整链路：  应用 -> mihomo(7890) -> 本测试上游(8888) -> 目标网站

注意：
  它本身【不提供任何翻墙能力】，只是把请求原样转发出去。
  因此能连上的站点，等于本机本来就能直连的站点。
  它的价值在于证明「代理链路 + 分流规则 + DNS 接管」是通的，
  让你在拿到真实上游之前就能确认架构没问题。

用法：
  python test_upstream.py            # 监听 127.0.0.1:8888
  python test_upstream.py 9000       # 自定义端口
"""
import os
import socket
import sys
import threading

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
BUF = 65536
TIMEOUT = 20


def log(msg):
    sys.stdout.write("[upstream] %s\n" % msg)
    sys.stdout.flush()


def pipe(src, dst):
    """双向转发，任一方向结束就关闭两端。"""
    try:
        while True:
            data = src.recv(BUF)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def read_headers(sock):
    """读取 HTTP 请求头，直到 CRLF CRLF。"""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(BUF)
        if not chunk:
            return None
        buf += chunk
        if len(buf) > 65536:
            return None
    return buf


def handle(conn, addr):
    try:
        conn.settimeout(TIMEOUT)
        raw = read_headers(conn)
        if not raw:
            return
        head, _, rest = raw.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        if not lines:
            return
        parts = lines[0].split()
        if len(parts) < 2:
            return
        method, target = parts[0].upper(), parts[1]

        if method == "CONNECT":
            # HTTPS 隧道
            host, _, port = target.partition(":")
            port = int(port or 443)
            log("CONNECT %s:%d" % (host, port))
            upstream = socket.create_connection((host, port), timeout=TIMEOUT)
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            conn.settimeout(None)
            upstream.settimeout(None)
            t = threading.Thread(target=pipe, args=(conn, upstream), daemon=True)
            t.start()
            pipe(upstream, conn)
        else:
            # 明文 HTTP 转发: 形如  GET http://host:port/path HTTP/1.1
            url = target
            if url.startswith("http://"):
                url = url[7:]
            elif url.startswith("https://"):
                url = url[8:]
            hostport, _, pathpart = url.partition("/")
            host_only, _, portstr = hostport.partition(":")
            port = int(portstr or 80)
            path = "/" + pathpart if pathpart else "/"
            log("%s http://%s:%d%s" % (method, host_only, port, path))

            upstream = socket.create_connection((host_only, port), timeout=TIMEOUT)
            newlines = [lines[0]]
            for ln in lines[1:]:
                if ln.lower().startswith(("proxy-connection:", "connection:")):
                    continue
                newlines.append(ln)
            newlines.append("Connection: close")
            req = "\r\n".join(newlines).encode("latin-1") + b"\r\n\r\n" + rest
            upstream.sendall(req)
            conn.settimeout(None)
            upstream.settimeout(None)
            pipe(upstream, conn)
    except Exception as e:
        log("error: %s" % e)
        try:
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        except OSError:
            pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(128)
    log("listening on %s:%d  (pid %d)" % (HOST, PORT, os.getpid()))
    log("扮演角色: 上游节点。本模块不提供翻墙能力，仅验证链路。")
    try:
        while True:
            conn, addr = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=handle, args=(conn, addr), daemon=True).start()
    except KeyboardInterrupt:
        log("bye")
    finally:
        srv.close()


if __name__ == "__main__":
    main()
