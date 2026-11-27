#!/usr/bin/env python3
"""The LeanFM-Limits header raises limits for one HTTP request (clause selfhost.mcp.limits, decision
mcp-limits).

Starts leanfm-server and leanfm-mcp on spare loopback ports and checks, over HTTP: protocol text over
64 KiB is refused naming textBytes and the header; the header LeanFM-Limits: textBytes=...,
argumentBytes=... lets the same request through, with limitsApplied saying so; a body over the hosted
endpoint's 256 KiB cap is refused with 413 naming the header, and accepted with requestBytes in it; a
malformed header is refused naming the limits; the server instructions document the header.
"""
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepalive_check import spare_port, start, until_listening  # noqa: E402


def post(port, body, header=None, path="/mcp"):
    data = json.dumps(body).encode()
    h = {"Content-Type": "application/json", "Accept": "application/json"}
    if header:
        h["LeanFM-Limits"] = header
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data, h)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def check(port, big, header=None):
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "session_check", "arguments": {"lean": big}}}
    return post(port, body, header)


def main():
    # a valid protocol padded with a comment to just over 64 KiB, under 256 KiB
    big = "-- " + "x" * 70000 + "\nprotocol P (A, B) { Ping from A to B; }"
    procs = []
    try:
        p1 = spare_port()
        srv = start("leanfm-server", {"LEANFM_PORT": str(p1)}); procs.append(srv); until_listening(srv)
        s, r = check(p1, big)
        text = r["result"]["content"][0]["text"]
        assert r["result"].get("isError") and "LeanFM-Limits: argumentBytes=" in text and "serverLog" in text, text[:300]
        print("ok: arguments over 64 KiB are refused, naming argumentBytes, the LeanFM-Limits header and serverLog")
        s, r = check(p1, big, "argumentBytes=200000")
        text = r["result"]["content"][0]["text"]
        assert r["result"].get("isError") and "LeanFM-Limits: textBytes=" in text, text[:300]
        print("ok: with only argumentBytes raised, protocol text over 64 KiB is refused, naming textBytes and the header")
        s, r = check(p1, big, "argumentBytes=200000, textBytes=200000")
        sc = r["result"]["structuredContent"]
        assert not r["result"].get("isError") and sc["verdict"] == "ok", r["result"]["content"][0]["text"][:300]
        assert sc["limitsApplied"]["limits"]["textBytes"]["applied"] == 200000, sc["limitsApplied"]
        print("ok: the header LeanFM-Limits: argumentBytes=200000, textBytes=200000 lets the same request through, and limitsApplied says so")
        # a call's own limits argument wins over the header for the names it gives
        body = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "session_check",
                "arguments": {"lean": big, "limits": {"textBytes": 100}}}}
        s, r = post(p1, body, "argumentBytes=200000, textBytes=200000")
        assert r["result"].get("isError") and "over 100 bytes" in r["result"]["content"][0]["text"], r
        print("ok: a name the call's limits argument gives wins over the header")
        s, r = check(p1, big, "textBytes=lots")
        assert s == 400 and "textBytes must be a whole number" in json.loads(r)["error"]["message"], (s, r)
        s, r = check(p1, big, "bogus=1")
        assert s == 400 and "unknown limit bogus" in json.loads(r)["error"]["message"], (s, r)
        print("ok: a malformed header is refused, naming the limits")
        s, r = post(p1, {"jsonrpc": "2.0", "id": 3, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}})
        instr = r["result"]["instructions"]
        assert "LeanFM-Limits: name=value" in instr and "requestBytes" in instr and "serverLog" in instr, instr[-800:]
        print("ok: the server instructions document the header, requestBytes and naming data with serverLog")
        # the hosted endpoint sizes a body at 256 KiB unless the header raises requestBytes
        p2 = spare_port()
        mcp = start("leanfm-mcp", {"LEANFM_MCP_PORT": str(p2)}); procs.append(mcp); until_listening(mcp)
        huge = "-- " + "x" * 300000 + "\nprotocol P (A, B) { Ping from A to B; }"
        s, r = check(p2, huge)
        assert s == 413 and "LeanFM-Limits: requestBytes=" in r, (s, r[:300])
        print("ok: the hosted endpoint refuses a 300 KB body with 413, naming LeanFM-Limits: requestBytes")
        s, r = check(p2, huge, "requestBytes=1000000, argumentBytes=1000000, textBytes=1000000")
        assert s == 200 and r["result"]["structuredContent"]["verdict"] == "ok", (s, str(r)[:300])
        print("ok: with LeanFM-Limits: requestBytes=1000000, argumentBytes=..., textBytes=... the same body is read and checked")
    finally:
        for p in procs:
            p.kill(); p.wait()


if __name__ == "__main__":
    main()
