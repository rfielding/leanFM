"""Ask the running LeanFM server (make serve) everything the book tour shows, and keep the answers in
data/: the MCP handshake and tool list, TicTacToe's draft and fixed protocols checked, drawn and decided,
Images' faithful rules, and the guinea pig cage's log checked by session_conform and its four claims by
check_signal (with their charts). The video draws only these answers. Usage: fetch.py"""
import json, os, sys, urllib.request
D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
OUT = os.path.join(D, "data"); os.makedirs(OUT, exist_ok=True)
URL = "http://127.0.0.1:8080/mcp"

def rpc(method, params=None):
    b = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
    r = urllib.request.Request(URL, json.dumps(b).encode(), {"Content-Type": "application/json", "Accept": "application/json"})
    return json.loads(urllib.request.urlopen(r, timeout=300).read())

def call(tool, args):
    res = rpc("tools/call", {"name": tool, "arguments": args})["result"]
    if res.get("isError"): sys.exit(f"{tool} refused: {res['content'][0]['text'][:300]}")
    return res.get("structuredContent") or json.loads(res["content"][0]["text"])

def save(name, obj): json.dump(obj, open(os.path.join(OUT, name + ".json"), "w"), indent=1)
def listing(name):
    t = open(os.path.join(ROOT, "book/generated", name + ".tex")).read()
    return t.split("\n", 1)[1].rsplit("\\end{lstlisting}", 1)[0].strip()

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "tour", "version": "1"}})["result"]
tools = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
save("mcp", {"server": init["serverInfo"], "tools": tools, "instructions": init.get("instructions", "")[:600]})

draft, fixed = listing("ctl-tictactoe-draft"), listing("ctl-tictactoe")
check = call("session_check", {"lean": draft})
save("ttt_draft", {"lean": draft, "verdict": check["verdict"], "reading": check["reading"],
                   "svg": call("session_diagram", {"lean": draft, "theme": "dark"})["svg"]})
ends = call("session_ctl", {"lean": draft, "formula": "(inevitably (on Result))"})
save("ttt_ends", {"verdict": ends["verdict"], "reading": ends["reading"], "evidence": ends["evidence"]})
reqs = [("Every game ends with a result", "(inevitably (on Result))"),
        ("O moves only after the game starts", "(precedes (on Joined) (on MoveO))"),
        ("O moves only when told it is its turn", "(precedes (on OTurn) (on MoveO))"),
        ("Every move by X is answered", "(stronglyImplies (on MoveX) (inevitably (or (on OTurn) (on Result))))"),
        ("A game can always still end", "(always (possibly stop))")]
fixed_check = call("session_check", {"lean": fixed})
save("ttt_roles", {r: fixed_check["projections"][r]["typestate"] for r in ("X", "O", "Referee")})
save("ttt_fixed", {"lean": fixed, "svg": call("session_diagram", {"lean": fixed, "theme": "dark"})["svg"],
                   "checks": [{"says": s, "formula": f, "verdict": call("session_ctl", {"lean": fixed, "formula": f})["verdict"]} for s, f in reqs]})

images = "protocol Images (Browser, Server) {\n  q: GetImage from Browser to Server;\n  choice {\n    Image from Server to Browser cause q;\n  } or {\n    NotFound from Server to Browser cause q;\n  }\n}"
rules = call("session_ctl", {"lean": images, "faithful": "rules"})
save("images", {"lean": images, "svg": call("session_diagram", {"lean": images, "theme": "dark"})["svg"], "rules": rules})

cage = open(os.path.join(ROOT, "examples/guinea-pigs/GuineaPigCage.leanfm")).read()
order = call("session_conform", {"lean": cage, "serverLog": "devices", "allowIncomplete": True})
claims = [("temperature stays between 18 and 26 C", "(always (and (above temp 18) (below temp 26)))"),
          ("water never below 100 ml for half an hour", "(never (throughout 1800 (below water 100)))"),
          ("a low bowl gets food within 10 minutes", "(always (implies (below food 20) (within 600 (on Dispense))))"),
          ("the webcam sees them move every two hours", "(always (within 7200 (above motion 0.3)))")]
answers = []
for says, c in claims:
    a = call("check_signal", {"claim": c, "serverLog": "devices", "theme": "dark"})
    answers.append({"says": says, "claim": c, "verdict": a["verdict"], "margin": a["margin"], "reading": a["reading"],
                    "firstFailure": a["firstFailure"], "cutShort": a["cutShort"], "svg": a["svg"], "source": a["source"]})
save("cage", {"lean": cage, "order": {"verdict": order["verdict"], "reading": order["reading"]}, "claims": answers})
print("tools:", len(tools), "| ttt draft ends:", ends["verdict"], "| cage:", order["verdict"], [a["verdict"] for a in answers])

# ── the deeper session-type segments: the book's protocols, asked again of the live server ──
def text_of(name): return listing(name)
def first(a, *keys):
    for k in keys:
        if k in a: return a[k]
P = {n: text_of(f"ctl-{n}") for n in ("placeorder", "construct-loop", "construct-bounded-loop", "construct-parallel", "include", "race", "blind", "realizable-jam")}
deep = {}
for n in ("placeorder", "construct-loop", "construct-bounded-loop", "construct-parallel", "include"):
    c = call("session_check", {"lean": P[n]})
    deep[n] = {"lean": P[n], "verdict": c["verdict"], "reading": c["reading"],
               "svg": call("session_diagram", {"lean": P[n], "theme": "dark"})["svg"],
               "roles": {r: v["typestate"] for r, v in c.get("projections", {}).items()}}
for n in ("race", "blind"):
    c = call("session_check", {"lean": P[n]})
    deep[n] = {"lean": P[n], "verdict": c["verdict"], "reading": c["reading"], "issues": c.get("issues", []),
               "svg": call("session_diagram", {"lean": P[n], "theme": "dark"})["svg"]}
borrow = "protocol Borrow (Client, Shop, Bank) {\n  q: Quote from Shop to Client;\n  Paid from Bank to Client cause q;\n}"
c = call("session_check", {"lean": borrow})
deep["borrow"] = {"lean": borrow, "verdict": c["verdict"], "reading": c["reading"], "issues": c.get("issues", [])}
r = call("session_ctl", {"lean": P["placeorder"], "faithful": "rules"})
deep["placeorder_rules"] = {"rules": [x["formula"] for x in r["rules"]], "typestates": r.get("typestates"), "lookahead": r.get("lookahead"), "reading": r["reading"]}
r = call("session_ctl", {"lean": P["construct-bounded-loop"], "faithful": "rules"})
deep["retry_rules"] = {"typestates": r.get("typestates"), "lookahead": r.get("lookahead"), "bits": r.get("bits"), "hiddenBits": r.get("hiddenBits"), "reading": r["reading"]}
where_log = text_of("ctl-where-log")
w = call("session_conform", {"lean": P["placeorder"], "events": [json.loads(l) for l in where_log.splitlines() if l.strip()]})
deep["where"] = {"log": where_log, "verdict": w["verdict"], "reading": w["reading"], "issues": w.get("issues", [])}
jam = call("session_realizable", {"lean": P["realizable-jam"]})
deep["jam"] = {"lean": P["realizable-jam"], "verdict": jam["verdict"], "reading": jam["reading"]}
jam0 = call("session_realizable", {"lean": P["realizable-jam"].replace("B[1]", "B")})
deep["jam0"] = {"verdict": jam0["verdict"], "reading": jam0["reading"]}
for n in ("images-no404", "branching"):
    deep[n] = text_of(f"ctl-{n}")
save("deep", deep)
print("deep:", {k: (v.get("verdict") if isinstance(v, dict) else "listing") for k, v in deep.items()})

# ── more of the book: LeanFM checking its own MCP traffic, and a simulated run ──
own = call("session_conform", {"file": "LeanFM/LLMGenerated/LeanFM.leanfm", "protocolName": "LeanFMMcp", "serverLog": "serve",
                               "lastLines": 2000, "allowIncomplete": True})
sim = call("session_simulate", {"lean": P["placeorder"], "instances": 3, "seed": 7})
evs = [{"session": e.get("session"), "from": e.get("src") or e.get("from"), "to": e.get("dst") or e.get("to"), "label": e.get("label"),
        "thread": e.get("thread")} for e in sim["events"]][:24]
more = {"own": {"verdict": own["verdict"], "reading": own["reading"], "source": own.get("source")},
        "sim": {"reading": sim.get("reading", ""), "events": evs, "sessions": sim.get("source", {}).get("sessions")}}
for n in ("mcp-suggest", "mcp-next", "mcp-checkctl", "images-truth", "images-openapi", "corpus", "mcp-ctl-disproved"):
    more[n] = open(os.path.join(ROOT, "book/generated", f"ctl-{n}.tex")).read()
save("more", more)
print("own:", own["verdict"], own["reading"][:120])
