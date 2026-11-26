#!/usr/bin/env python3
"""LeanFM logs LeanFMMcp's own messages (selfhost.session.real-events, decision session-real-events).

Starts leanfm-server on a spare loopback port with its standard output (where its event lines go) in
a scratch file, plays one host conversation against it the way /view does (params._meta naming the
session and cause, host steps as notifications/leanfm/host-event), and checks the log: the protocol's
messages in order, Disk reads around the reads, refusals as refusals, forged host events dropped, a
request without a session logging Call and Answer only, and session_conform reading the session.
"""
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepalive_check import BIN, spare_port  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LISTED = "LeanFM/LLMGenerated/LeanFM.leanfm"


def post(port, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
        return json.loads(raw) if raw.strip() else None


def by0(events, disk):
    """The request a Disk read was made for: the nearest request event before it in the log."""
    i = events.index(disk)
    return next(e for e in reversed(events[:i]) if e["label"] in ("ProjectView", "SessionTool"))


def main():
    out = tempfile.NamedTemporaryFile(prefix="leanfm-real-events-", suffix=".log", delete=False)
    port = spare_port()
    proc = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=ROOT, env={**os.environ, "LEANFM_PORT": str(port)},
                            stdout=out, stderr=subprocess.DEVNULL)
    try:
        for _ in range(400):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        S = secrets.token_hex(8)
        V = S + "-v1"
        n = [0]
        prev = [None]
        rid = [0]

        def host(label, cause=None, session=S, id_=None):
            n[0] += 1
            params = {"session": session, "id": id_ or f"host@{S}:{n[0]}", "label": label}
            if cause:
                params["cause"] = cause
            if prev[0] and id_ is None:
                params["prev"] = prev[0]
            if id_ is None:
                prev[0] = params["id"]
            assert post(port, {"jsonrpc": "2.0", "method": "notifications/leanfm/host-event", "params": params}) is None
            return params["id"]

        def call(method, params, cause=None, meta=True, session=S):
            rid[0] += 1
            params = dict(params)
            if meta:
                params["_meta"] = {"leanfm/session": session, **({"leanfm/cause": cause} if cause else {})}
            return post(port, {"jsonrpc": "2.0", "id": rid[0], "method": method, "params": params})

        call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check", "version": "1"}})
        call("tools/list", {})
        o = host("Open")
        r = call("tools/call", {"name": "project_view", "arguments": {"project": "LeanFM", "stage": "requirements"}}, o)
        assert "result" in r and not r["result"].get("isError"), r
        host("Render", o)
        load = host("Load", session=V)
        r = call("tools/call", {"name": "session_check", "arguments": {"project": "LeanFM", "file": LISTED, "protocolName": "LeanFMMcp"}}, load, session=V)
        assert not r["result"].get("isError"), r
        host("Drawn", load, session=V)
        load2 = host("Load", session=V)
        r = call("tools/call", {"name": "session_check", "arguments": {"project": "LeanFM", "file": "LeanFM/LLMGenerated/Nope.leanfm"}}, load2, session=V)
        host("Refused", load2, session=V)
        # forged or malformed host events are dropped
        host("ReadFile", o, id_=f"host@{S}:90")
        host("Drawn", o, session="0" * 16, id_=f"host@{S}:91")
        host("Drawn", "bad cause!", id_=f"host@{S}:92")
        # a request without a session is logged as Call and Answer only
        call("tools/list", {}, meta=False)
        time.sleep(0.3)
    finally:
        proc.kill(); proc.wait()
        out.close()
    text = open(out.name).read()
    os.unlink(out.name)
    events = [json.loads(l) for l in text.split("\n") if l.startswith('{"type":"leanFM"')]
    mine = [e for e in events if e.get("protocol") == "LeanFMMcp"]
    labels = [e["label"] for e in mine]
    want = ["Initialize", "Initialized", "ListTools", "Tools", "Open", "ProjectView", "ReadRoot", "Listing", "Shown", "Render",
            "Load", "SessionTool", "ReadFile", "FileText", "Checked", "Drawn", "Load", "SessionTool", "ReadFile", "FileText", "NotListed", "Refused"]
    assert labels == want, ("the LeanFMMcp events are not the conversation", labels)
    assert all(e["session"].split("-")[0] == S for e in mine), "an event names another conversation"
    disk = [e for e in mine if e["label"] in ("ReadRoot", "Listing", "ReadFile", "FileText")]
    assert all(e["session"].startswith(by0(mine, e)["session"] + "-r") for e in disk), "a Disk read is not a child session of its request's session"
    assert all(e["session"] == V for e in mine if e["label"] in ("Load", "Drawn", "Refused", "NotListed", "Checked")), "the view's browsing is not its own child session"
    print("ok: one host conversation is logged as LeanFMMcp's messages in order, each Disk read a child session of its request's, the view's browsing the child session -v1")
    by = {e["id"]: e for e in mine}
    pv = next(e for e in mine if e["label"] == "ProjectView")
    assert pv["cause"] == o and pv["from"] == "Host" and pv["to"] == "Server", pv
    assert by[next(e for e in mine if e["label"] == "Listing")["cause"]]["label"] == "ReadRoot"
    assert by[next(e for e in mine if e["label"] == "Shown")["cause"]]["label"] == "ProjectView"
    hosts = [e for e in mine if e["actor"].startswith("host@")]
    assert [e["label"] for e in hosts] == ["Open", "Render", "Load", "Drawn", "Load", "Refused"] and all(e["actor"] == f"host@{S}" for e in hosts), hosts
    assert all(e["id"].startswith(f"host@{S}:") for e in hosts)
    assert next(e for e in hosts if e["label"] == "Render")["from"] == "Host" and next(e for e in hosts if e["label"] == "Load")["from"] == "View"
    print("ok: causes link each request to the host step it answers and each answer to its request; host events carry actor host@SESSION and the protocol's sender and receiver")
    assert labels.count("Refused") == 1 and "ReadFile" not in [e["label"] for e in hosts] and not any(e["id"].endswith((":90", ":91", ":92")) for e in mine)
    print("ok: a host event claiming Disk's ReadFile, one with another session's id and one with a bad cause are not written")
    assert "NotListed" in labels and "Checked" in labels and labels.index("NotListed") > labels.index("Checked")
    calls = [e for e in events if e.get("protocol") == "McpCall"]
    assert len([e for e in calls if e["label"] == "Call"]) == rid[0], "every MCP request still logs its Call"
    assert sum(1 for e in mine if e["label"] == "ListTools") == 1, "a request without a session wrote a LeanFMMcp event"
    print("ok: a file the project does not list is logged as NotListed, not Checked; a request without a session logs Call and Answer only")
    # the real conversation checked against the protocol it claims to speak
    leanfm = open(os.path.join(ROOT, LISTED)).read()
    port = spare_port()
    proc = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=ROOT, env={**os.environ, "LEANFM_PORT": str(port)},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(400):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        good = "\n".join(json.dumps({"type": "leanFM", **e}) for e in mine)
        r = post(port, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "session_conform", "arguments":
                 {"lean": leanfm, "protocolName": "LeanFMMcp", "log": good, "allowIncomplete": True}}})["result"]
        sc = r["structuredContent"]
        assert sc["verdict"] == "conforms", sc.get("issues")
        print("ok: session_conform finds the real conversation following LeanFMMcp: " + sc["reading"])
    finally:
        proc.kill(); proc.wait()


if __name__ == "__main__":
    main()
