"""Ask the LeanFM MCP server about one Paxos slot over UDP across two islands.

Needs a running server (`make serve` in the LeanFM root) and the draft tasks written by
`spec/PaxosUdp.lean`. Every request and response is kept under reports/mcp/ so the verdicts in the
book can be traced to the exact question asked.

Run from projects/PaxosKV: python3 scripts/mcp_paxos_udp.py
"""
import json, os, re, sys

sys.path.insert(0, os.path.dirname(__file__))
import mcp  # noqa: E402

OUT = "reports/mcp"
VARIANTS = ["correct", "broken", "partitioned", "lossy"]

def after(m): return {"after": m}
def chosen(): return {"or": [after("ChosenA"), after("ChosenB")]}
def only(a, b): return {"stronglyImplies": [after(a), {"AG": {"not": after(b)}}]}

FORMULAS = {
    "agreement": ("no two different values are both chosen",
                  {"and": [only("ChosenA", "ChosenB"), only("ChosenB", "ChosenA")]}),
    "possiblyA": ("A can be chosen", {"EF": after("ChosenA")}),
    "possiblyB": ("B can be chosen", {"EF": after("ChosenB")}),
    "conflict": ("A is chosen, and later B", {"EF": {"and": [after("ChosenA"), {"EF": after("ChosenB")}]}}),
    "mustDecide": ("a value must be chosen", {"AF": chosen()}),
    "canDecide": ("until a value is chosen, one can still be chosen", {"AW": [{"EF": chosen()}, chosen()]}),
}
ASK = {
    "correct": ["agreement", "possiblyA", "possiblyB", "conflict", "mustDecide", "canDecide"],
    "broken": ["agreement", "conflict"],
    "partitioned": ["possiblyA", "possiblyB", "canDecide"],
    "lossy": ["possiblyA", "mustDecide"],
}
PREDICATES = [
    "the replicas in us and eu agree on the chosen value",
    "ChosenA and ChosenB are never both delivered",
    "kv2 has promised ballot 2",
]

def load(variant, kind):
    with open(f"{OUT}/paxos-udp-{variant}.{kind}.json") as f:
        return json.load(f)

def save(name, value):
    with open(f"{OUT}/{name}.json", "w") as f:
        json.dump(value, f, indent=1, sort_keys=True)
        f.write("\n")

def from_state(task, state):
    return dict(task, initial=state)

# ---------------------------------------------------------------- paths to event traces

def parse(key):
    parts = key.split("|")
    lists = lambda s: [x.strip() for x in s.strip("[]").split(",") if x.strip()]
    return {"accepted": lists(parts[1]), "delivered": re.findall(r"\((\w+), (\d)\)", parts[5])}

def trace(task_id, path, states):
    """Turn a check_ctl path into event envelopes with prevIds (per sender) and causeIds."""
    events, last_by, sent = [], {}, {}
    for k in range(1, len(path)):
        label, prev, cur = path[k]["message"], states[path[k - 1]["state"]], states[path[k]["state"]]
        p, c = parse(prev), parse(cur)
        cause, src, dst = [], "learner", "web"
        if label == "Accept1A":
            src, dst = "kv0", "replicas"
        elif label == "Prepare2":
            src, dst = "kv2", "replicas"
        elif label.startswith("Accept2"):
            src, dst = "kv2", "replicas"
            cause = [e["id"] for e in events if e["message"].startswith("Promise")]
        elif label.startswith("Promise"):
            src, dst = "kv" + label[-1], "kv2"
            cause = [sent["Prepare2"]] if "Prepare2" in sent else []
        elif label.startswith("Accepted"):
            a = int(label[-1])
            src, dst = f"kv{a}", "learner"
            ballot = "Accept" + c["accepted"][a]
            cause = [sent[ballot]] if ballot in sent else []
        elif label == "Rejected":
            new = [d for d in c["delivered"] if d not in p["delivered"]]
            if new:
                msg, a = new[0]
                src = f"kv{a}"
                key = {"P": "Prepare2"}.get(msg, "Accept" + msg[1:])
                dst = {"Prepare2": "kv2", "Accept1A": "kv0"}.get(key, "kv2")
                cause = [sent[key]] if key in sent else []
        elif label.startswith("Chosen"):
            v = label[-1]
            cause = [e["id"] for e in events if e["message"].startswith("Accepted")
                     and c["accepted"][int(e["message"][-1])].endswith(v)]
        eid = f"e{k}"
        ev = {"id": eid, "task": task_id, "src": src, "dst": dst, "message": label,
              "prevIds": [last_by[src]] if src in last_by else [], "causeIds": cause}
        events.append(ev)
        last_by[src] = eid
        sent[label] = eid
    draft = {"id": task_id, "initial": path[0]["state"], "terminals": [],
             "states": sorted({p["state"] for p in path}),
             "transitions": [{"src": path[k - 1]["state"], "dst": path[k]["state"], "message": path[k]["message"]}
                             for k in range(1, len(path))]}
    return {"events": events, "drafts": [draft]}

# ---------------------------------------------------------------- the session

def main():
    os.makedirs(OUT, exist_ok=True)
    init = mcp.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "paxos-kv", "version": "1"}})
    tools = [t["name"] for t in mcp.rpc("tools/list")["tools"]]
    reference = mcp.resource("leanfm://language/logic-reference")
    results = {"server": init["serverInfo"], "tools": tools,
               "logicReferenceBytes": len(reference), "explain": {}, "ctl": {}, "traces": {}, "classify": {}}

    for name, (say, f) in FORMULAS.items():
        r, _ = mcp.tool("explain_formula", {"formula": f})
        results["explain"][name] = {"say": say, "reading": r.get("reading"), "lints": r.get("lints", []),
                                    "mode": r.get("mode")}

    for v in VARIANTS:
        task, states = load(v, "task"), load(v, "states")
        for name in ASK[v]:
            r, err = mcp.tool("check_ctl", {"task": task, "formula": FORMULAS[name][1]})
            entry = {"verdict": r.get("verdict"), "reason": r.get("reason"), "evidence": r.get("evidence"),
                     "reachableNodes": r.get("reachableNodes"), "deadlocks": len(r.get("deadlocks", [])),
                     "isError": err}
            # A witness for EF(a and EF b) stops where a holds; ask again from there for the rest.
            if name == "conflict" and r.get("verdict") == "proved":
                mid = r["evidence"]["path"][-1]["state"]
                r2, _ = mcp.tool("check_ctl", {"task": from_state(task, mid), "formula": {"EF": after("ChosenB")}})
                entry["continuation"] = r2.get("evidence")
                path = r["evidence"]["path"] + r2["evidence"]["path"][1:]
                entry["path"] = path
                t, _ = mcp.tool("check_trace", trace(task["id"], path, states))
                results["traces"][f"{v}.conflict"] = t
            results["ctl"][f"{v}.{name}"] = entry
            print(f"{v:12} {name:11} {entry['verdict']}", flush=True)

    small = load("partitioned", "task")   # declares the full alphabet, so names resolve
    r, _ = mcp.tool("classify_requirement", {"task": small, "predicates": PREDICATES})
    results["classify"] = r
    r, _ = mcp.tool("classify_requirement", {"task": small, "formula": FORMULAS["agreement"][1]})
    results["classifyAgreement"] = r
    r, _ = mcp.tool("validate_generated_artifacts", {})
    results["validate"] = r
    save("results", results)

if __name__ == "__main__":
    main()
