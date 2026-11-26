#!/usr/bin/env python3
"""HTTP keep-alive on both LeanFM servers (selfhost.mcp.keepalive).

Starts leanfm-server and leanfm-mcp on spare loopback ports with small limits and checks, over raw
sockets: two requests sent together are both answered, in order, the first with keep-alive; a
Connection: close request is answered and the connection closes; the request quota closes the
connection after its last answer; a malformed request is answered 400 and closed; one connection
over the cap is answered 503; and a bad setting stops the server at startup.

Launch timing (selfhost.env.launch, selfhost.session.event-log): started with LEANFM_LAUNCHED_NS from
the shell clock, each server reports how long it took to reach main, at most INIT_BOUND_MS; the check
waits for its Listening event line (never a timer), and its startup event lines conform to ServerStart
with StartsQuickly fulfilled, by that server's own session_conform; a stamp that is not a number, or
one far in the future, stops it naming the variable; without a stamp the listening line has no note.
"""
import os
import json
import re
import select
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, ".lake", "build", "bin")


def spare_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start(exe, env):
    proc = subprocess.Popen([os.path.join(BIN, exe)], cwd=ROOT, env={**os.environ, **env},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc


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


INIT_BOUND_MS = 1000


def until_listening(proc, timeout=60):
    """Everything the server wrote until its Listening event line: wait for the event, not a time."""
    buf, end = b"", time.time() + timeout
    while b'"label":"Listening"' not in buf:
        if time.time() > end:
            raise SystemExit("no Listening event line: " + buf.decode()[-400:])
        ready, _, _ = select.select([proc.stdout], [], [], 1)
        if ready:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise SystemExit("the server exited before listening: " + buf.decode()[-400:])
            buf += chunk
    return buf.decode()


def protocol_text(name):
    """LeanFM.leanfm up to the end of protocol `name`: a text's last protocol is the one checked."""
    text = open(os.path.join(ROOT, "LeanFM", "LLMGenerated", "LeanFM.leanfm")).read()
    start = text.index("protocol " + name + " (")
    return text[:text.index("\n}\n", start) + 3]


SERVER_START = protocol_text("ServerStart")


def launch_check(exe, port_var, limits):
    port = spare_port()
    proc = start(exe, {**limits, port_var: str(port), "LEANFM_LAUNCHED_NS": str(time.time_ns())})
    try:
        log = until_listening(proc)
        line = next(l for l in log.split("\n") if "listening on" in l)
        m = re.search(r"initialized in (\d+) ms", line)
        assert m, (exe, "no initialization note", line)
        ms = int(m.group(1))
        assert ms <= INIT_BOUND_MS, f"{exe} took {ms} ms from launch to main (bound {INIT_BOUND_MS} ms): something heavy runs before main"
        print(f"ok: {exe} reports reaching main {ms} ms after launch (bound {INIT_BOUND_MS} ms)")
        req = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": "session_conform", "arguments": {"lean": SERVER_START, "log": log}}}
        answer = json.loads(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/mcp",
            json.dumps(req).encode(), {"Content-Type": "application/json"}), timeout=60).read())
        sc = answer["result"].get("structuredContent") or {}
        assert sc.get("name") == "ServerStart", (exe, "checked the wrong protocol", sc.get("name"))
        assert sc.get("verdict") == "conforms", (exe, "startup log", sc.get("reading"), answer)
        obligations = [o for r in (sc.get("deadlineReports") or []) for o in r["report"]["obligations"]]
        assert [o["status"] for o in obligations if o["name"] == "StartsQuickly"] == ["fulfilled"], (exe, obligations)
        assert sc.get("logEventLines") == 3, (exe, "event lines", sc.get("logEventLines"))
        print(f"ok: {exe}'s startup event lines conform to ServerStart, StartsQuickly fulfilled, other lines ignored")
        entered = next(json.loads(l) for l in log.split("\n") if '"label":"MainEntered"' in l)
        pay = entered.get("payload") or {}
        assert isinstance(pay.get("commit"), str) and len(pay["commit"]) == 40, (exe, "no commit", pay.get("commit"))
        assert isinstance(pay.get("changedFiles"), list) and isinstance(pay.get("clean"), bool), (exe, pay)
        names = [x["name"] for x in pay.get("settings", [])]
        assert "LEANFM_LAUNCHED_NS" in names and "LEANFM_KEEPALIVE_REQUESTS" in names, (exe, names)
        print(f"ok: {exe}'s MainEntered names commit {pay['commit'][:10]}, {'clean' if pay['clean'] else str(len(pay['changedFiles'])) + ' changed files'}, and {len(names)} settings")
    finally:
        proc.kill()
        proc.wait()
    port = spare_port()
    proc = start(exe, {**limits, port_var: str(port)})
    try:
        log = until_listening(proc)
        line = next(l for l in log.split("\n") if "listening on" in l)
        assert "initialized in" not in line, (exe, "note without a stamp", line)
        assert '"label":"Launch"' not in log, (exe, "a Launch event without a stamp", log)
    finally:
        proc.kill()
        proc.wait()
    print(f"ok: {exe} without a stamp prints no initialization note")
    for stamp in ["soon", str(time.time_ns() + 3600 * 10**9)]:
        bad = start(exe, {**limits, port_var: str(spare_port()), "LEANFM_LAUNCHED_NS": stamp})
        bad.wait(timeout=30)
        err = bad.stderr.read().decode()
        assert bad.returncode != 0 and "LEANFM_LAUNCHED_NS" in err, (exe, "bad stamp", stamp, bad.returncode, err)
    print(f"ok: {exe} stops naming LEANFM_LAUNCHED_NS for a stamp that is not a number or is in the future")


def secret_check(limits):
    """selfhost.env.registry: a secret's value is written nowhere; it is recorded only as set."""
    secret = "s3cr3t-" + str(time.time_ns())
    port = spare_port()
    proc = start("leanfm-mcp", {**limits, "LEANFM_MCP_PORT": str(port), "LEANFM_MCP_TOKEN": secret})
    try:
        log = until_listening(proc)
    finally:
        proc.kill(); proc.wait()
    err = proc.stderr.read().decode()
    assert secret not in log and secret not in err, "the secret's value was written"
    entered = next(json.loads(l) for l in log.split("\n") if '"label":"MainEntered"' in l)
    token = next(x for x in entered["payload"]["settings"] if x["name"] == "LEANFM_MCP_TOKEN")
    assert token.get("set") is True and token.get("secret") is True and "value" not in token, token
    print("ok: LEANFM_MCP_TOKEN is recorded as set and secret, and its value appears nowhere in the output")


def chatui_off_check(limits):
    """selfhost.chatui.switch: by default leanfm-server serves MCP and the views, never the chat UI."""
    port = spare_port()
    proc = start("leanfm-server", {**limits, "LEANFM_PORT": str(port)})
    try:
        until_listening(proc)
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=30)
            raise SystemExit("the chat UI answered GET / while LEANFM_CHATUI is off")
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            assert e.code == 404 and "LEANFM_CHATUI" in body, (e.code, body)
        assert urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=30).status == 200
        req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode(),
                                     {"Content-Type": "application/json"})
        assert "result" in json.loads(urllib.request.urlopen(req, timeout=60).read())
        print("ok: by default leanfm-server answers / with 404 naming LEANFM_CHATUI, and still serves /health and /mcp")
    finally:
        proc.kill(); proc.wait()
    bad = start("leanfm-server", {**limits, "LEANFM_PORT": str(spare_port()), "LEANFM_CHATUI": "maybe"})
    bad.wait(timeout=30)
    err = bad.stderr.read().decode()
    assert bad.returncode != 0 and "LEANFM_CHATUI" in err, (bad.returncode, err)
    print("ok: LEANFM_CHATUI=maybe stops leanfm-server at startup, naming the variable")


def main():
    limits = {"LEANFM_KEEPALIVE_REQUESTS": "3", "LEANFM_KEEPALIVE_SECONDS": "5", "LEANFM_MAX_CONNECTIONS": "2"}
    for exe, port_var, path in [("leanfm-server", "LEANFM_PORT", "/health"), ("leanfm-mcp", "LEANFM_MCP_PORT", "/healthz")]:
        port = spare_port()
        proc = start(exe, {**limits, port_var: str(port)})
        try:
            until_listening(proc)
            check(exe, port, path)
        finally:
            proc.kill()
            proc.wait()
        bad = start(exe, {**limits, port_var: str(spare_port()), "LEANFM_KEEPALIVE_SECONDS": "soon"})
        bad.wait(timeout=30)
        err = bad.stderr.read().decode()
        assert bad.returncode != 0 and "LEANFM_KEEPALIVE_SECONDS" in err, (exe, "bad setting", bad.returncode, err)
        print(f"ok: {exe} stops at startup naming a bad keep-alive setting")
        launch_check(exe, port_var, limits)
    chatui_off_check(limits)
    secret_check(limits)


if __name__ == "__main__":
    main()
