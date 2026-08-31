#!/usr/bin/env python3
import socket, sys
# Minimal capture listener: accept one connection, record the raw request bytes,
# return a short 200 so the client does not hang, then exit.
port = int(sys.argv[1]); outf = sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(1)
sys.stderr.write("LISTENING\n"); sys.stderr.flush()
s.settimeout(20)
try:
    conn, _ = s.accept()
    conn.settimeout(2)
    data = b""
    try:
        while len(data) < 4096:
            chunk = conn.recv(1024)
            if not chunk: break
            data += chunk
    except socket.timeout:
        pass
    open(outf, "wb").write(data)
    body = b"hi"
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body))
    conn.close()
except socket.timeout:
    open(outf, "wb").write(b"")   # no connection arrived
s.close()
