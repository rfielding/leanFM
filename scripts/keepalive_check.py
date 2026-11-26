#!/usr/bin/env python3
"""HTTP keep-alive on both LeanFM servers (selfhost.mcp.keepalive).

Starts leanfm-server and leanfm-mcp on spare loopback ports with small limits and checks, over raw
sockets: two requests sent together are both answered, in order, the first with keep-alive; a
Connection: close request is answered and the connection closes; the request quota closes the
connection after its last answer; a malformed request is answered 400 and closed; one connection
over the cap is answered 503; and a bad setting stops the server at startup.
"""
import os
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, ".lake", "build", "bin")


def spare_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start(exe, env):
    proc = subprocess.Popen([os.path.join(BIN, exe)], cwd=ROOT, env={**os.environ, **env},
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return proc


def wait_up(port, proc):
    for _ in range(200):
        if proc.poll() is not None:
            raise SystemExit(f"server exited: {proc.stderr.read().decode()}")
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    raise SystemExit("server did not start")


def read_responses(sock, count, timeout=10):
    """Read up to `count` HTTP responses (headers and Content-Length body); stop when the peer closes."""
    sock.settimeout(timeout)
    data, out = b"", []
    while len(out) < count:
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                return out, True
            data += chunk
        head, rest = data.split(b"\r\n\r\n", 1)
        headers = {}
        for line in head.decode().split("\r\n")[1:]:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        n = int(headers.get("content-length", "0"))
        while len(rest) < n:
            chunk = sock.recv(65536)
            if not chunk:
                return out, True
            rest += chunk
        out.append((int(head.split(b" ")[1]), headers))
        data = rest[n:]
    try:
        sock.settimeout(1)
        closed = sock.recv(1) == b""
    except socket.timeout:
        closed = False
    return out, closed


def get(path, close=False):
    return (f"GET {path} HTTP/1.1\r\nHost: localhost\r\n" + ("Connection: close\r\n" if close else "") + "\r\n").encode()


def check(name, port, path):
    # two requests together: both answered in order, the first kept alive
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(get(path) + get(path))
    rs, _ = read_responses(s, 2)
    assert len(rs) == 2 and all(st == 200 for st, _ in rs), (name, "pipelined", rs)
    assert rs[0][1].get("connection") == "keep-alive", (name, "first kept alive", rs[0])
    s.close()
    print(f"ok: {name} answers two requests sent together on one connection, in order")
    # Connection: close is answered and closed
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(get(path, close=True))
    rs, closed = read_responses(s, 1)
    assert rs and rs[0][1].get("connection") == "close" and closed, (name, "close", rs, closed)
    s.close()
    print(f"ok: {name} closes after a Connection: close request")
    # the quota (3 here) closes after the last answer
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(get(path) * 4)
    rs, closed = read_responses(s, 4)
    assert len(rs) == 3 and rs[2][1].get("connection") == "close" and closed, (name, "quota", rs, closed)
    s.close()
    print(f"ok: {name} closes after its request quota")
    # a malformed request is answered 400 and closed
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(b"GET / HTTP/1.1\r\nContent-Length: nope\r\n\r\n")
    rs, closed = read_responses(s, 1)
    assert rs and rs[0][0] == 400 and closed, (name, "malformed", rs, closed)
    s.close()
    print(f"ok: {name} answers a malformed request 400 and closes")
    # the connection cap (2 here): a third open connection is answered 503
    a = socket.create_connection(("127.0.0.1", port))
    b = socket.create_connection(("127.0.0.1", port))
    time.sleep(0.3)
    c = socket.create_connection(("127.0.0.1", port))
    rs, _ = read_responses(c, 1)
    assert rs and rs[0][0] == 503, (name, "cap", rs)
    for x in (a, b, c):
        x.close()
    print(f"ok: {name} answers 503 beyond its connection cap")


def main():
    limits = {"LEANFM_KEEPALIVE_REQUESTS": "3", "LEANFM_KEEPALIVE_SECONDS": "5", "LEANFM_MAX_CONNECTIONS": "2"}
    for exe, port_var, path in [("leanfm-server", "LEANFM_PORT", "/health"), ("leanfm-mcp", "LEANFM_MCP_PORT", "/healthz")]:
        port = spare_port()
        proc = start(exe, {**limits, port_var: str(port)})
        try:
            wait_up(port, proc)
            time.sleep(0.2)
            check(exe, port, path)
        finally:
            proc.kill()
            proc.wait()
        bad = start(exe, {**limits, port_var: str(spare_port()), "LEANFM_KEEPALIVE_SECONDS": "soon"})
        bad.wait(timeout=30)
        err = bad.stderr.read().decode()
        assert bad.returncode != 0 and "LEANFM_KEEPALIVE_SECONDS" in err, (exe, "bad setting", bad.returncode, err)
        print(f"ok: {exe} stops at startup naming a bad keep-alive setting")


if __name__ == "__main__":
    main()
