#!/usr/bin/env python3
"""The stdio relay (selfhost.mcp.forward): leanfm-mcp --stdio --forward URL shares a running HTTP
server with clients that can only start a command (Claude Desktop, Codex).

Through the relay, initialize and tools/list are answered by a running leanfm-server; a notification
writes nothing; with the server stopped a request waits up to LEANFM_FORWARD_WAIT_SECONDS and is then
answered with an error naming the URL, and the relay keeps running; with the server started again the
next request is answered; a relay started before its server holds the first request until the server
listens and answers it normally, writing Stalled and Resumed event lines on standard error; a forward
URL to another host, https, --forward without --stdio and a bad wait setting are refused.
"""
import json
import os
import select
import socket
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, ".lake", "build", "bin")


def spare_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_server(port):
    proc = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=ROOT, env={**os.environ, "LEANFM_PORT": str(port)},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(200):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return proc
        except OSError:
            time.sleep(0.05)
    raise SystemExit("leanfm-server did not start")


def ask(relay, message, expect_reply=True, timeout=60):
    relay.stdin.write((json.dumps(message) + "\n").encode())
    relay.stdin.flush()
    ready, _, _ = select.select([relay.stdout], [], [], timeout if expect_reply else 1.5)
    if not ready:
        return None
    return json.loads(relay.stdout.readline())


def main():
    port = spare_port()
    url = f"http://127.0.0.1:{port}/mcp"
    server = start_server(port)
    relay = subprocess.Popen([os.path.join(BIN, "leanfm-mcp"), "--stdio", "--forward", url], cwd=ROOT,
                             env={**os.environ, "LEANFM_FORWARD_WAIT_SECONDS": "3"},
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        r = ask(relay, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        assert r and r.get("id") == 1 and "serverInfo" in r.get("result", {}), r
        print("ok: initialize is answered through the relay")
        r = ask(relay, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert r and any(t["name"] == "session_ctl" for t in r["result"]["tools"]), r
        print("ok: tools/list is answered through the relay")
        r = ask(relay, {"jsonrpc": "2.0", "method": "notifications/initialized"}, expect_reply=False)
        assert r is None, r
        print("ok: a notification writes nothing")
        server.kill(); server.wait()
        t0 = time.time()
        r = ask(relay, {"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
        waited = time.time() - t0
        assert r and r.get("id") == 3 and url in r["error"]["message"] and "make serve" in r["error"]["message"], r
        assert waited >= 2.5, f"the error came after {waited:.1f} s, before the 3 s wait bound"
        assert relay.poll() is None, "the relay must keep running"
        print(f"ok: with the server stopped the relay waits for it ({waited:.1f} s), then answers an error naming the URL and keeps running")
        server = start_server(port)
        r = ask(relay, {"jsonrpc": "2.0", "id": 4, "method": "tools/list"})
        assert r and r.get("id") == 4 and "result" in r, r
        print("ok: with the server started again the next request is answered")
    finally:
        relay.kill(); relay.wait()
        server.kill(); server.wait()
    # a relay started before its server: the first request waits for the server to listen
    port = spare_port()
    url = f"http://127.0.0.1:{port}/mcp"
    relay = subprocess.Popen([os.path.join(BIN, "leanfm-mcp"), "--stdio", "--forward", url], cwd=ROOT,
                             env={**os.environ, "LEANFM_FORWARD_WAIT_SECONDS": "30"},
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    server = None
    try:
        relay.stdin.write((json.dumps({"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {}}) + "\n").encode())
        relay.stdin.flush()
        time.sleep(1.5)
        server = start_server(port)
        ready, _, _ = select.select([relay.stdout], [], [], 60)
        assert ready, "the held request was never answered"
        r = json.loads(relay.stdout.readline())
        assert r.get("id") == 7 and "serverInfo" in r.get("result", {}), r
        print("ok: a relay started before its server holds the first request and answers it once the server listens")
    finally:
        relay.kill(); relay.wait()
        if server:
            server.kill(); server.wait()
    err = relay.stderr.read().decode()
    events = [json.loads(l) for l in err.split("\n") if l.startswith('{"type":"leanFM"')]
    labels = [e["label"] for e in events]
    assert labels[:2] == ["Stalled", "Resumed"], ("the wait is not written as Stalled then Resumed", err[-600:])
    assert events[1].get("cause") == events[0]["id"], ("Resumed must name its Stalled as cause", events)
    print("ok: the wait is written on standard error as the event lines Stalled and Resumed")
    p = subprocess.run([os.path.join(BIN, "leanfm-mcp"), "--stdio", "--forward", url], cwd=ROOT, input=b"",
                       env={**os.environ, "LEANFM_FORWARD_WAIT_SECONDS": "forever"}, capture_output=True, timeout=30)
    assert p.returncode != 0 and b"LEANFM_FORWARD_WAIT_SECONDS" in p.stderr, (p.returncode, p.stderr)
    print("ok: a wait setting that is not a whole number of seconds from 0 to 600 is refused at startup")
    for args in (["--stdio", "--forward", "http://10.0.0.5:8080/mcp"], ["--stdio", "--forward", "https://127.0.0.1:8080/mcp"],
                 ["--forward", url]):
        p = subprocess.run([os.path.join(BIN, "leanfm-mcp")] + args, cwd=ROOT, input=b"", capture_output=True, timeout=30)
        assert p.returncode != 0, (args, p.returncode)
    print("ok: off-machine and https forward URLs, and --forward without --stdio, are refused")


if __name__ == "__main__":
    main()
