#!/usr/bin/env python3
"""A run of McpCall, the evidence for "Every MCP request a server takes is answered"
(clause selfhost.requirements.standing, decision requirement-standing).

Drives leanfm-mcp over stdio with initialize, tools/list and a few tool calls, as any MCP client
would, and writes one Call and one Answer event per request, each pair its own session, to
LeanFM/LLMGenerated/runs/mcp-call.jsonl. The log names no implementation detail, so the same driver
and the same requirement judge any MCP server. Then it asks the server for LeanFM's implementation
list and checks that the requirement stands as proved or tested on this run.

Then a run of LeanFMMcp, LeanFM's own MCP conversation: a leanfm-server of its own on a spare port,
its event lines kept, and LeanFM's standalone viewer opened against it in headless Chrome on a
protocol file (the host page's Open and Render, the view's Page and Load, the server's answers and
disk reads). The one conversation's LeanFMMcp events go to LeanFM/LLMGenerated/runs/leanfm-mcp.jsonl,
which LeanFMImplementation names as evidence for LeanFM.leanfm's requirements over LeanFMMcp.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepalive_check import BIN, ROOT, spare_port  # noqa: E402
import tempfile, time, urllib.request

RUN = os.path.join("LeanFM", "LLMGenerated", "runs", "mcp-call.jsonl")
MCP_RUN = os.path.join("LeanFM", "LLMGenerated", "runs", "leanfm-mcp.jsonl")
START_RUN = os.path.join("LeanFM", "LLMGenerated", "runs", "server-start.jsonl")
# requirements over LeanFMMcp the run should show; the rest stay as the run leaves them
MCP_REQS = ["The MCP conversation follows LeanFMMcp", "No project view or tool before the server is initialized",
            "Every page the view asks for is shown or refused", "Every protocol the view loads is drawn or refused",
            "A file the project does not list is refused", "A server listens only after reaching main",
            "The session ends only with Bye", "The session can always end"]
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


def leanfm_mcp_run():
    """LeanFMMcp's events of one viewer conversation with a server of this run's own."""
    from playwright.sync_api import sync_playwright
    port = spare_port()
    out = tempfile.NamedTemporaryFile(prefix="leanfm-run-", suffix=".log", delete=False)
    srv = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=ROOT, stdout=out, stderr=subprocess.STDOUT,
                           env={**os.environ, "LEANFM_PORT": str(port), "LEANFM_LAUNCHED_NS": str(time.time_ns())})
    status = lambda: subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
    before = status()
    try:
        end = time.time() + 60
        while '"label":"Listening"' not in open(out.name).read():
            if srv.poll() is not None or time.time() > end:
                raise SystemExit("FAIL: the run's leanfm-server did not listen: " + open(out.name).read()[-400:])
            time.sleep(0.2)
        fds = lambda: len(os.listdir(f"/proc/{srv.pid}/fd"))
        base = fds()
        with sync_playwright() as p:
            b = p.chromium.launch(executable_path="/usr/bin/google-chrome")
            pg = b.new_page()
            pg.goto(f"http://127.0.0.1:{port}/view?project=LeanFM&file=examples/sessions/TicTacToe.leanfm")
            # the host page writes Drawn when the named file's answer is shown: wait for that event line
            end = time.time() + 90
            while '"label":"Drawn"' not in open(out.name).read():
                if time.time() > end: raise SystemExit("FAIL: the viewer never drew the protocol")
                time.sleep(0.5)
            # the View asks to load a file the project does not list: LeanFMMcp's NotListed, then Refused
            refused = pg.evaluate("""async () => {
              const load = await hostEvent("Load", null, viewSession);
              const a = await mcp("tools/call", { name: "session_check", arguments: { project: "LeanFM", file: "not/listed.leanfm" } }, load, viewSession);
              await hostEvent(a && !a.isError ? "Drawn" : "Refused", load, viewSession);
              return !!(a && a.isError);
            }""")
            if not refused: raise SystemExit("FAIL: a file the project does not list was not refused")
            # the conversation ends as LeanFMMcp says: Close, Done, Quit, Bye, ByeDone
            if not pg.evaluate("bye()"): raise SystemExit("FAIL: the host page did not end its conversation")
            pg.wait_for_timeout(1500)
            b.close()
        # hazard files.handles: many requests that read the disk leave no file open behind them
        for k in range(40):
            body = {"jsonrpc": "2.0", "id": k, "method": "tools/call", "params": {"name": "session_explore",
                    "arguments": {"project": "LeanFM", "file": "examples/sessions/TicTacToe.leanfm"}}}
            req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(),
                                         {"Content-Type": "application/json", "Accept": "application/json"})
            urllib.request.urlopen(req, timeout=120).read()
        if fds() > base + 4:
            raise SystemExit(f"FAIL: the server holds {fds()} files after 40 reads, {base} before: a handle leaks")
        print(f"ok: 40 requests that read the disk leave the server holding {fds()} files ({base} before)")
    finally:
        srv.terminate(); srv.wait(timeout=30)
    # hazard disk.exhaustion: serving MCP, the viewer included, writes nothing to the checkout
    if status() != before:
        raise SystemExit("FAIL: the server changed the checkout while serving:\n" + status())
    print("ok: the server wrote nothing to the checkout while serving")
    lines = [json.loads(l) for l in open(out.name) if l.startswith('{"type":"leanFM"')]
    os.unlink(out.name)
    hosts = sorted({e["session"] for e in lines if str(e.get("actor", "")).startswith("host@") and "-" not in e["session"]})
    if len(hosts) != 1:
        raise SystemExit(f"FAIL: expected one viewer conversation, found {len(hosts)}")
    sid = hosts[0]
    mine = [e for e in lines if e.get("protocol") == "LeanFMMcp" and (e["session"] == sid or e["session"].startswith(sid + "-"))]
    start = [e for e in lines if e.get("protocol") == "ServerStart"]
    return mine, start


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
    evs, start = leanfm_mcp_run()
    open(os.path.join(ROOT, MCP_RUN), "w").write("".join(json.dumps(e) + "\n" for e in evs))
    open(os.path.join(ROOT, START_RUN), "w").write("".join(json.dumps(e) + "\n" for e in start))
    print(f"ok: {len(start)} ServerStart events of the run's server written to {START_RUN}")
    print(f"ok: {len(evs)} LeanFMMcp events of one viewer conversation written to {MCP_RUN}")
    rows = {r.get("id"): r for r in implementation_rows()}
    for req in MCP_REQS:
        row = rows.get(req)
        if not row or row.get("status") not in ("proved", "tested"):
            raise SystemExit(f"FAIL: {req!r} stands {row and row.get('status')}: {row and row.get('reading')}")
        print(f"ok: {req!r} stands {row['status']}: {row.get('reading')}")


if __name__ == "__main__":
    main()
