"""Turn the recorded GoServer traffic (data/traffic.json, from play.py) into a LeanFM log and ask the
running service (make serve) what it is: session_conform against GoServer's own session type, with no
session ids, so the sessions are derived. Writes data/log.json (the log and how it was reduced) and
data/conform.json (LeanFM's answer). Usage: python3 -I video/goserver/fetch.py"""
import json, os, re, sys, urllib.request
from pathlib import Path
D = Path(__file__).resolve().parent
ROOT = D.parents[1]
DATA = D / "data"
MAX_EVENTS = 200  # session_conform takes at most 64 KiB of arguments: the opening of the run

def call(tool, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}).encode()
    req = urllib.request.Request("http://127.0.0.1:8080/mcp", body, {"content-type": "application/json", "accept": "application/json, text/event-stream"})
    r = json.load(urllib.request.urlopen(req))["result"]
    return r.get("structuredContent") or {"error": r["content"][0]["text"]}

# the session type's own routes: each request label and the labels that answer it
text = open(ROOT / "projects/GoServer/source/cmd/demo/static/session/goserver.leanfm").read()
route_label = {r: l for l, r in re.findall(r"\w+: (\w+) from Person to Server route \"POST (/api/\w+)\"", text)}
answers = {}
# ids are local to a protocol (many name their request q), so answers are matched inside each block
for block in re.split(r"\nprotocol ", text):
    for req_id, label, route in re.findall(r"(\w+): (\w+) from Person to Server route \"POST (/api/\w+)\"", block):
        for resp in re.findall(rf"(\w+) from Server to Person cause {req_id}\b", block):
            answers.setdefault(label, [])
            if resp not in answers[label]: answers[label].append(resp)

traffic = json.load(open(DATA / "traffic.json"))
IDS = ("sessionId", "gameId", "requestId", "roomId")
calls, skipped = [], {}
for person, ts in traffic["traffic"].items():
    for t in ts:
        if t["route"] not in route_label:
            skipped[t["route"]] = skipped.get(t["route"], 0) + 1
            continue
        calls.append((t["sent"], t["received"], person, t))
calls.sort(key=lambda c: (c[0], c[2]))
events, prev = [], {}
renamed = 0
for k, (sent, received, person, t) in enumerate(calls):
    label = route_label[t["route"]]
    req = t["req"] or {}; res = t["res"] or {}
    q = {"id": f"q{k}", "label": label, "from": f"Person/{person}", "to": "Server/s", "ts": str(sent * 1000000),
         "fields": {f: str(req[f]) for f in IDS if f in req}}
    if person in prev: q["prev"] = prev[person]
    prev[person] = q["id"]
    # the answer: the success the protocol names, RequestRejected for a rejection, SignInRefused for a refused sign-in
    if label == "IssueSession":
        resp = "SessionIssued" if t["status"] == 200 else "SignInRefused"
    elif "code" in res and "task" in res:
        resp = "RequestRejected"
    else:
        resp = next(a for a in answers[label] if a != "RequestRejected")
    fields = {f: str(res[f]) for f in IDS if f in res}
    if resp == "SessionIssued" and "session" in res:
        fields["sessionId"] = res["session"]; renamed += 1  # the server names it session; the spec, sessionId
    a = {"id": f"a{k}", "label": resp, "from": "Server/s", "to": f"Person/{person}", "cause": q["id"], "ts": str(received * 1000000 + 1), "fields": fields}
    events += [q, a]
events.sort(key=lambda e: int(e["ts"]))
# session tokens are credentials: each distinct token becomes s1, s2, ... by first appearance, so equal
# tokens stay equal (all the identity equations need) and no token is kept
alias = {}
for e in events:
    v = e["fields"].get("sessionId")
    if v is not None:
        e["fields"]["sessionId"] = alias.setdefault(v, f"s{len(alias) + 1}")
window = events[:MAX_EVENTS]
# an answer whose request fell outside the window is dropped with it
ids = {e["id"] for e in window}
window = [e for e in window if e.get("cause") is None or e["cause"] in ids]
for e in window:
    if e.get("prev") and e["prev"] not in ids: e.pop("prev")
json.dump({"source": "data/traffic.json, recorded by play.py from seven browsers",
           "reducer": "session tokens replaced by s1, s2, ... (equal tokens equal); route to request label and its answers from goserver.leanfm; a rejection (code and task) is RequestRejected; each answer's cause is its request, each person's requests are chained by prev in the order they were sent; only sessionId, gameId, requestId and roomId are logged",
           "findings": {"SessionIssued names the minted id 'session' on the wire; the spec names it sessionId (read as sessionId here)": renamed,
                        "routes the session type does not model, left out": skipped},
           "events": len(events), "window": len(window), "log": window},
          open(DATA / "log.json", "w"), indent=1)
ans = call("session_conform", {"example": "goserver", "events": window, "allowIncomplete": True})
json.dump(ans, open(DATA / "conform.json", "w"), indent=1)
# before the fix: the same log against the session type as it was when the run was recorded, where a
# person's lobby lists games one request at a time (data/goserver-before.leanfm, kept from then)
before_path = DATA / "goserver-before.leanfm"
if before_path.exists():
    json.dump(call("session_conform", {"lean": before_path.read_text(), "events": window, "allowIncomplete": True}),
              open(DATA / "conform_before.json", "w"), indent=1)
# the CTL GoServer implies, every formula decided (reports/ctl-translation/translate_full.py)
import shutil
shutil.copy(ROOT / "reports/ctl-translation/goserver.json", DATA / "ctl_goserver.json")
# the sequence diagram of every protocol GoServer runs (session_explore focus), and which protocol
# defines each message: the CTL scene shows a formula beside the diagram its messages come from
tree = call("session_explore", {"example": "goserver"})["tree"]
included = ["GoServer"] + [n["label"].split()[1] for n in tree if n["kind"] == "include"]
included = list(dict.fromkeys(included))
blocks = {b.split()[0]: b for b in re.split(r"\nprotocol ", text)[1:]}
defines = {}
for name in included:
    for lab in re.findall(r"(?:^|[\s:])(\w+) from \w+ to \w+", blocks.get(name, "")) + re.findall(r"(\w+) at \w+;", blocks.get(name, "")):
        defines.setdefault(lab, name)
diagrams = {name: call("session_explore", {"example": "goserver", "focus": name}).get("svg", "") for name in included}
# the whole protocol's drawing is too large for the tool's answer; the panel's goserver.svg is the same
# generated drawing (spec/SessionPanel.lean writes it with LeanFM's annotatedModel)
if not diagrams.get("GoServer"):
    diagrams["GoServer"] = open(ROOT / "projects/GoServer/source/cmd/demo/static/session/goserver.svg").read()
json.dump({"protocols": included, "defines": defines, "svg": diagrams,
           "source": "session_explore focus on each protocol GoServer includes; defines: the first included protocol whose text has the message"},
          open(DATA / "diagrams.json", "w"))
print("diagrams:", included)
print("calls kept", len(calls), "skipped", skipped, "events", len(events), "window", len(window))
print(ans.get("reading") or ans.get("error"))
for s in (ans.get("derivedSessions") or {}).get("sessions", [])[:40]:
    print("  ", s["key"], s["count"], s.get("parents", s.get("parent", "")))
for i in (ans.get("issues") or [])[:8]: print("  issue:", i[:200])
