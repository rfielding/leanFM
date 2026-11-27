#!/usr/bin/env python3
"""Reading a log by line ranges (selfhost.session.log-paging, decision session-log-paging).

In a scratch directory holding logs/serve.log, starts leanfm-server on a spare loopback port and
checks GET /tools/logs?log=serve with Range: lines=... (206, Content-Range, ETag, 416, redaction,
appends leave old lines unchanged, a line still being written is not served, a replaced log has a
new ETag) and session_conform with serverLog and lastLines over its /mcp endpoint.
"""
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepalive_check import BIN, spare_port, until_listening  # noqa: E402
import subprocess  # noqa: E402

LINES = 5000


def get(port, rng=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/tools/logs?log=serve", headers={"Range": rng} if rng else {})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


def conform(port, args):
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "session_conform", "arguments": args}}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(), {"Content-Type": "application/json"})
    reply = json.loads(urllib.request.urlopen(req, timeout=60).read())
    text = reply["result"]["content"][0]["text"]
    if reply["result"].get("isError"):
        raise SystemExit("session_conform refused: " + text)
    return reply["result"].get("structuredContent") or json.loads(text)


def main():
    tmp = tempfile.mkdtemp(prefix="leanfm-logrange-")
    log = os.path.join(tmp, "logs", "serve.log")
    os.makedirs(os.path.dirname(log))
    # a project app's standard log (selfhost.project.logs), and a project that is a symlink out of projects/
    app = os.path.join(tmp, "projects", "Cage")
    os.makedirs(os.path.join(app, "logs"))
    open(os.path.join(app, "manifest.json"), "w").write(json.dumps({"display_name": "Cage"}))
    with open(os.path.join(app, "logs", "events.log"), "w") as f:
        for i in range(3):
            f.write(json.dumps({"id": f"cage:{i}", "session": f"s{i}", "from": "A", "to": "B", "label": "Ping"}).replace('{"id"', '{"type":"leanFM","id"', 1) + "\n")
    outside = tempfile.mkdtemp(prefix="leanfm-outside-")
    os.makedirs(os.path.join(outside, "logs"))
    open(os.path.join(outside, "manifest.json"), "w").write("{}")
    open(os.path.join(outside, "logs", "events.log"), "w").write("secret\n")
    os.symlink(outside, os.path.join(tmp, "projects", "Escape"))
    with open(log, "w") as f:
        for i in range(1, LINES + 1):
            f.write(f"plain line {i}\n" if i != 11 else "Authorization: Bearer hunter2secretvalue\n")
    port = spare_port()
    proc = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=tmp, env={**os.environ, "LEANFM_PORT": str(port)},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        until_listening(proc)
        s, h, b = get(port, "lines=10-12")
        assert s == 206 and h.get("Content-Range") == f"lines 10-12/{LINES}", (s, h)
        assert h.get("Accept-Ranges") == "lines" and h.get("ETag", "").startswith('"'), h
        got = b.split("\n")
        assert got[0] == "plain line 10" and got[2] == "plain line 12" and len(got) == 4, got
        assert "hunter2" not in b and "[redacted]" in b, "a 206 answer carried a token the 200 answer redacts"
        print("ok: Range lines=10-12 answers 206 with those three lines, Content-Range, Accept-Ranges and an ETag; the Bearer token is redacted")
        s, h, b = get(port, "lines=-2")
        assert s == 206 and b == f"plain line {LINES - 1}\nplain line {LINES}\n", (s, b)
        s, h, b = get(port, "lines=6000-")
        assert s == 416 and h.get("Content-Range") == f"lines */{LINES}", (s, h)
        s, h, b = get(port, "bytes=0-10")
        assert s == 416, s
        s, h, b = get(port)
        assert s == 200 and h.get("Accept-Ranges") == "lines", (s, h)
        print("ok: lines=-2 gives the last two, a start past the end and a byte range answer 416 with the total, no Range answers 200")
        tag = get(port, "lines=1-1")[1]["ETag"]
        with open(log, "a") as f:
            f.write("appended 1\nappended 2\nhalf a line")
        s, h, b10 = get(port, "lines=10-12")
        assert h.get("Content-Range") == f"lines 10-12/{LINES + 2}" and b10 == got[0] + "\n" + "\n".join(got[1:3]) + "\n", (h, b10)
        assert h["ETag"] == tag, "appending changed the fingerprint"
        s, h, b = get(port, "lines=-1")
        assert b == "appended 2\n", b
        print("ok: appending raises the total and leaves lines 10-12 and the ETag unchanged; a line without its newline is not served")
        req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}).encode(), {"Content-Type": "application/json"})
        tools = json.loads(urllib.request.urlopen(req, timeout=60).read())["result"]["tools"]
        schema = next(t for t in tools if t["name"] == "session_conform")["inputSchema"]
        assert not schema.get("required") and "lastLines" in schema["properties"], schema.get("required")
        print("ok: session_conform's input schema requires none of events, log and serverLog, and offers lastLines")
        req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
              "params": {"name": "server_logs", "arguments": {}}}).encode(), {"Content-Type": "application/json"})
        listing = json.loads(urllib.request.urlopen(req, timeout=60).read())["result"]["content"][0]["text"]
        assert "Cage/events" in listing and "projects/Cage/logs/events.log" in listing and "Escape" not in listing, listing[-600:]
        pc = conform(port, {"lean": "protocol P (A, B) { Ping from A to B; }", "serverLog": "Cage/events"})
        assert pc["verdict"] == "conforms" and pc["source"]["log"] == "Cage/events", pc.get("reading")
        try:
            conform(port, {"lean": "protocol P (A, B) { Ping from A to B; }", "serverLog": "Escape/events"})
            raise AssertionError("a project symlinked out of projects/ was read")
        except SystemExit as e:
            assert "must be one of" in str(e), e
        print("ok: server_logs lists a project's logs/events.log as Cage/events, serverLog reads it, and a project symlinked out of projects/ has no log")
        leanfm = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "LeanFM", "LLMGenerated", "LeanFM.leanfm")).read()
        mc = conform(port, {"lean": leanfm, "protocolName": "McpCall", "events": []})
        assert "McpCall:" in json.dumps(mc) and "LeanFMMcp:" not in json.dumps(mc), json.dumps(mc)[:300]
        try:
            conform(port, {"lean": leanfm, "protocolName": "Nope", "events": []})
            raise AssertionError("an unknown protocolName was accepted")
        except SystemExit as e:
            assert "Nope is not a protocol" in str(e) and "McpCall" in str(e), e
        print("ok: protocolName picks McpCall of LeanFM.leanfm, and a name it does not define is refused naming those it does")
        a = conform(port, {"lean": "protocol P (A, B) { Ping from A to B; }", "serverLog": "serve", "lastLines": 2})
        assert a["fromLine"] == LINES + 1 and a["logLines"] == LINES + 2 and a["nextLine"] == LINES + 3, a
        assert a["logFingerprint"] == tag.strip('"'), (a["logFingerprint"], tag)
        print("ok: session_conform with serverLog and lastLines 2 answers fromLine, logLines, nextLine and the same fingerprint")
        src = a["source"]
        assert src["kind"] == "log" and src["log"] == "serve" and src["path"] == "logs/serve.log", src
        assert (src["fromLine"], src["lastLine"], src["logLines"]) == (LINES + 1, LINES + 2, LINES + 2) and src["writers"] == [], src
        print("ok: its source says kind log, log serve, path logs/serve.log, lines 5001-5002 of 5002 and no writers")
        size = os.path.getsize(log)
        assert size > 65536, size
        big = conform(port, {"lean": "protocol P (A, B) { Ping from A to B; }", "serverLog": "serve", "lastLines": LINES + 2})
        assert big["source"]["fromLine"] == 1 and big["source"]["lastLine"] == LINES + 2, big["source"]
        try:
            conform(port, {"lean": "protocol P (A, B) { Ping from A to B; }", "log": open(log).read()})
            raise AssertionError("a client-sent log over 64 KiB was accepted")
        except SystemExit as e:
            assert "exceed 65536" in str(e), e
        print(f"ok: a window of the whole {size}-byte log read by the server is checked, while the same text sent by a client is refused at 64 KiB")
        P = "protocol P (Client, Server) { Call from Client to Server; Done from Server to Client; }"
        evs = []
        for k in range(3):
            evs.append({"id": f"w:{2*k+1}", "session": f"call{k}", "from": "Client", "to": "Server", "label": "Call", "actor": "w"})
            evs.append({"id": f"w:{2*k+2}", "session": f"call{k}", "from": "Server", "to": "Client", "label": "Done", "actor": "w", "cause": f"w:{2*k+1}"})
        g = conform(port, {"lean": P, "events": evs})
        assert g["source"] == {"kind": "given", "events": 6}, g["source"]
        threads = sorted({e["thread"] for e in g["events"]})
        assert threads == ["Client@w", "Server@w"], threads
        print("ok: events given in the call have source kind given; three calls written by one process w run on two threads, Client@w and Server@w")
        body = {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "session_simulate", "arguments": {"lean": P, "seed": 7, "instances": 5}}}
        req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(), {"Content-Type": "application/json"})
        sim = json.loads(urllib.request.urlopen(req, timeout=60).read())["result"]["structuredContent"]
        assert sim["source"]["kind"] == "simulated" and sim["source"]["seed"] == 7 and sim["source"]["protocol"] == "P", sim["source"]
        assert sorted({e["thread"] for e in sim["events"]}) == ["Client", "Server"], sorted({e["thread"] for e in sim["events"]})
        print("ok: session_simulate says source kind simulated with its seed, and its five sessions run on one thread per role")
        with open(log, "w") as f:
            f.write("a new log\n")
        s, h, b = get(port, "lines=1-1")
        assert h["ETag"] != tag and h["Content-Range"] == "lines 1-1/1" and b == "a new log\n", (h, b)
        print("ok: a replaced log has a new ETag and its own lines")
        # check_signal reads a log by name too (selfhost.mcp.logic.signal)
        with open(log, "w") as f:
            for i in range(700):
                temp = 20 + (i % 10) * 0.5 + (7 if i == 650 else 0)
                f.write(json.dumps({"type": "leanFM", "id": f"arduino:{i+1}", "session": "cage", "from": "Arduino", "to": "Hub",
                                    "label": "Reading", "ts": str(1794528000000000000 + i * 600000000000),
                                    "payload": {"temp": temp, "water": 600 - i * 0.5}}).replace('{"type": "leanFM", ', '{"type":"leanFM",') + "\n")
        size = os.path.getsize(log)
        assert size > 65536, size
        def signal(args):
            body = {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "check_signal", "arguments": args}}
            req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(), {"Content-Type": "application/json"})
            r = json.loads(urllib.request.urlopen(req, timeout=60).read())["result"]
            return r, (r.get("structuredContent") or json.loads(r["content"][0]["text"]) if not r.get("isError") else None)
        r, a = signal({"claim": "(always (below temp 26))", "serverLog": "serve"})
        assert a and a["verdict"] == "fails" and a["samples"] == 700, a
        assert a["source"] == {"kind": "log", "log": "serve", "fromLine": 1, "lastLine": 700, "logLines": 700}, a["source"]
        r, _ = signal({"claim": "(always (below temp 26))", "log": open(log).read()})
        assert r.get("isError") and "exceed 65536" in r["content"][0]["text"], r
        r, a = signal({"claim": "(always (below temp 26))", "serverLog": "serve", "lastLines": 10})
        assert a["source"]["fromLine"] == 691 and a["verdict"] == "holds", a["source"]
        print(f"ok: check_signal reads the whole {size}-byte log by serverLog (source log serve, lines 1-700), the same text sent as log is refused at 64 KiB, and lastLines 10 reads only the end")
    finally:
        proc.kill(); proc.wait()
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(outside, ignore_errors=True)


if __name__ == "__main__":
    main()
