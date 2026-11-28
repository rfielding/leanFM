#!/usr/bin/env python3
"""A run of McpCall, the evidence for "Every MCP request a server takes is answered"
(clause selfhost.requirements.standing, decision requirement-standing).

Drives leanfm-mcp over stdio with initialize, tools/list and a few tool calls, as any MCP client
would, and writes one Call and one Answer event per request, each pair its own session, to
LeanFM/LLMGenerated/runs/mcp-call.jsonl. The log names no implementation detail, so the same driver
and the same requirement judge any MCP server. Then it asks the server for LeanFM's implementation
list and checks that the requirement stands as proved or tested on this run.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepalive_check import BIN, ROOT  # noqa: E402

RUN = os.path.join("LeanFM", "LLMGenerated", "runs", "mcp-call.jsonl")
REQ = "Every MCP request a server takes is answered"

REQUESTS = [
    ("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "run-log", "version": "1"}}),
    ("tools/list", {}),
    ("tools/call", {"name": "server_info", "arguments": {}}),
    ("tools/call", {"name": "project_view", "arguments": {}}),
    ("tools/call", {"name": "explain_formula", "arguments": {"formula": "(leadsTo (on Call) (on Answer))"}}),
]


def stdio(msgs):
    p = subprocess.run([os.path.join(BIN, "leanfm-mcp"), "--stdio", "--root", ROOT], cwd=ROOT,
                       input="".join(json.dumps(m) + "\n" for m in msgs), capture_output=True, text=True, timeout=300)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip().startswith("{")]


def requests():
    msgs = []
    for i, (method, params) in enumerate(REQUESTS, 1):
        msgs.append({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
        if method == "initialize":
            msgs.append({"jsonrpc": "2.0", "method": "notifications/initialized"})
    return msgs


def events(replies):
    answered = {r.get("id") for r in replies if "result" in r or "error" in r}
    out = []
    for i in range(1, len(REQUESTS) + 1):
        out.append({"id": f"c{i}", "session": f"r{i}", "from": "Client", "to": "Server", "label": "Call"})
        if i in answered:
            out.append({"id": f"a{i}", "session": f"r{i}", "from": "Server", "to": "Client", "label": "Answer", "cause": f"c{i}"})
    return out


def implementation_rows():
    msgs = requests()[:2] + [{"jsonrpc": "2.0", "id": 99, "method": "tools/call", "params": {"name": "project_view",
            "arguments": {"stage": "requirements", "section": "implementations"}}}]
    reply = [r for r in stdio(msgs) if r.get("id") == 99]
    if not reply:
        raise SystemExit("FAIL: project_view gave no answer")
    return reply[0]["result"].get("structuredContent", {}).get("page", {}).get("items", [])


def main():
    replies = stdio(requests())
    evs = events(replies)
    calls = sum(1 for e in evs if e["label"] == "Call")
    answers = sum(1 for e in evs if e["label"] == "Answer")
    path = os.path.join(ROOT, RUN)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = "".join(json.dumps(e) + "\n" for e in evs)
    if not os.path.exists(path) or open(path).read() != text:
        open(path, "w").write(text)
    print(f"ok: {calls} calls, {answers} answers written to {RUN}")
    rows = [r for r in implementation_rows() if r.get("id") == REQ]
    if not rows:
        raise SystemExit(f"FAIL: LeanFM's implementation list has no row for {REQ!r}")
    row = rows[0]
    if row.get("status") not in ("proved", "tested"):
        raise SystemExit(f"FAIL: {REQ!r} stands {row.get('status')}: {row.get('reading')}")
    print(f"ok: {REQ!r} stands {row['status']}: {row.get('reading')}")


if __name__ == "__main__":
    main()
