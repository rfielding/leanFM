"""Turn a protocol (sequence, choice, cause) into pure future CTL, then check every formula with
LeanFM's session_ctl on the protocol and on broken variants of it. Usage (with make serve running): python3 -I translate.py cases.json report.json"""
import json, re, sys, urllib.request
URL = "http://127.0.0.1:8080/mcp"

def call(tool, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}).encode()
    req = urllib.request.Request(URL, body, {"content-type": "application/json", "accept": "application/json, text/event-stream"})
    r = json.load(urllib.request.urlopen(req))["result"]
    return r.get("structuredContent") or {"error": r["content"][0]["text"]}

# ---- structure from session_explore: a body is a list of items; an item is ("msg", label, cause) or ("choice", [body, ...])
def structure(lean):
    tree = call("session_explore", {"lean": lean})["tree"]
    kids = {}
    for n in tree: kids.setdefault(n.get("parent"), []).append(n)
    def body(pid):
        out = []
        for n in kids.get(pid, []):
            if n["kind"] == "message":
                m = re.search(r"cause (\w+)", n.get("detail", ""))
                out.append(("msg", n["message"], m.group(1) if m else None))
            elif n["kind"] == "choice":
                out.append(("choice", [body(b["id"]) for b in kids.get(n["id"], []) if b["kind"] == "branch"]))
            elif n["kind"] in ("loop", "par", "sessions", "include"):
                raise SystemExit(f"this exercise covers sequence, choice and cause only, not {n['kind']}")
        return out
    return body(0)

def firsts(b):
    if not b: return set()
    x = b[0]
    return {x[1]} if x[0] == "msg" else set().union(*[firsts(br) for br in x[1]])
def lasts(b):
    if not b: return set()
    x = b[-1]
    return {x[1]} if x[0] == "msg" else set().union(*[lasts(br) for br in x[1]])
def labels(b):
    out = set()
    for x in b: out |= {x[1]} if x[0] == "msg" else set().union(*[labels(br) for br in x[1]])
    return out

after = lambda l: {"after": l}
def anyof(ls):
    ls = sorted(ls)
    return after(ls[0]) if len(ls) == 1 else {"or": [after(l) for l in ls]}
imp = lambda a, b: {"implies": [a, b]}
NOT = lambda a: {"not": a}

def translate(lean):
    """The formulas the protocol's structure implies, each named by the rule and messages it comes from."""
    top = structure(lean)
    out = [("start", f"every session starts with {' or '.join(sorted(firsts(top)))}", {"AX": anyof(firsts(top))})]
    ids = {}  # message id -> label, for causes
    for m in re.finditer(r"(\w+):\s*(\w+)\s+from", lean): ids[m.group(1)] = m.group(2)
    answers = {}
    def walk(b):
        for i, x in enumerate(b):
            if x[0] == "msg" and x[2]:
                answers.setdefault(ids.get(x[2], x[2]), set()).add(x[1])
            if x[0] == "choice":
                brs = x[1]
                for bi, br in enumerate(brs):
                    walk(br)
                    others = set().union(*[labels(o) for j, o in enumerate(brs) if j != bi]) if len(brs) > 1 else set()
                    if others:
                        out.append(("choice", f"after {' or '.join(sorted(firsts(br)))}, never {' or '.join(sorted(others))}",
                                    {"AG": imp(anyof(firsts(br)), {"AG": NOT(anyof(others))})}))
            if i + 1 < len(b):
                prev_l, next_f = lasts([x]), firsts([b[i + 1]])
                out.append(("succession", f"after {' or '.join(sorted(prev_l))} comes {' or '.join(sorted(next_f))}",
                            {"AG": imp(anyof(prev_l), {"AX": anyof(next_f)})}))
                out.append(("order", f"no {' or '.join(sorted(next_f))} before {' or '.join(sorted(prev_l))}",
                            NOT({"EU": [NOT(anyof(prev_l)), anyof(next_f)]})))
    walk(top)
    for q, rs in answers.items():
        out.append(("cause", f"no {' or '.join(sorted(rs))} before its request {q}", NOT({"EU": [NOT(after(q)), anyof(rs)]})))
        out.append(("cause", f"every {q} is answered ({' or '.join(sorted(rs))})", {"AG": imp(after(q), {"AF": anyof(rs)})}))
    for l in sorted(labels(top)):
        out.append(("possible", f"{l} can happen", {"EF": after(l)}))
    out.append(("end", f"after {' or '.join(sorted(lasts(top)))} the session may end", {"AG": imp(anyof(lasts(top)), "terminal")}))
    out.append(("end", "every session ends", {"AF": "terminal"}))
    return out

def check(lean, formulas):
    res = []
    for rule, name, f in formulas:
        a = call("session_ctl", {"lean": lean, "formula": f})
        res.append((rule, name, a.get("verdict", a.get("error", "?"))))
    return res

if __name__ == "__main__":
    cases = json.load(open(sys.argv[1]))
    report = {}
    for c in cases:
        fs = translate(c["lean"])
        own = check(c["lean"], fs)
        r = {"formulas": [{"rule": a, "name": n, "formula": f, "verdict": v} for (a, n, f), (_, _, v) in zip(fs, own)], "variants": []}
        for v in c.get("variants", []):
            got = check(v["lean"], fs)
            failed = [n for (_, n, verdict) in got if verdict not in ("proved",)]
            r["variants"].append({"name": v["name"], "failed": failed})
        report[c["name"]] = r
        print(f"== {c['name']}: {len(fs)} formulas, {sum(1 for x in own if x[2] == 'proved')} hold on the protocol")
        for x in own:
            if x[2] != "proved": print("   DOES NOT HOLD:", x)
        for v in r["variants"]:
            print(f"   variant {v['name']}: {len(v['failed'])} formulas fail" + (f" (first: {v['failed'][0]})" if v['failed'] else "  <-- NOT CAUGHT"))
    json.dump(report, open(sys.argv[2], "w"), indent=1)
