"""Ask the LeanFM MCP server about IslandUploads across two islands.

Needs a running server (`make serve` in the LeanFM root) and the draft tasks written by
`spec/Islands.lean`. Every answer is kept in reports/mcp/results.json.

Run from projects/IslandUploads: python3 scripts/mcp_islands.py
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(__file__))
import mcp  # noqa: E402

OUT = "reports/mcp"

def after(m): return {"after": m}

FORMULAS = {
    "converge": ("from every state the shards can still converge", {"AG": {"EF": after("Synced")}}),
    "mustConverge": ("the shards must converge", {"AF": after("Synced")}),
    "writeInPartition": ("a write commits while the islands are apart",
                         {"EF": {"and": [after("Partition"), {"EU": [{"not": after("Heal")}, after("CommitA1")]}]}}),
    "reverseJump": ("imports finish in reverse order: the cursor stays at 0, then the last to finish moves it to 3",
                    {"EF": {"and": [after("ImportA3to0"), {"EF": {"and": [after("ImportA2to0"), {"EF": after("ImportA1to3")}]}}]}}),
    "noSkip": ("the feed never skips a readable record", {"never": after("Missed")}),
    "noLeak": ("no read is allowed that a held concurrent policy denies",
               {"never": {"or": [after("LeakA"), after("LeakB")]}}),
    "readDuringPartition": ("eu can read under the policy it holds", {"EF": after("ReadB")}),
    "xStarts": ("an import that can succeed gets a lane while others keep failing", {"AF": after("StartX")}),
    "xFinishes": ("it also finishes, without assuming fair delivery", {"AF": after("DoneX")}),
    "smallFirst": ("a small import starts before any large one finishes",
                   {"AU": [{"not": {"or": [after("DoneB1"), after("DoneB2"), after("DoneB3")]}}, after("StartS")]}),
}
ASK = {
    "repl-ordered": ["converge", "mustConverge", "writeInPartition"],
    "repl-unordered": ["converge"],
    "repl-cursor": ["converge"],
    "lanes-max": ["converge"],
    "lanes-contiguous": ["converge", "reverseJump"],
    "retry-hold": ["xStarts"],
    "retry-yield": ["xStarts", "xFinishes"],
    "sched-shared": ["smallFirst"],
    "sched-reserved": ["smallFirst"],
    "feed-byDt": ["noSkip"],
    "feed-visibleAtBegin": ["noSkip"],
    "feed-visibleAtCommit": ["noSkip"],
    "policy-latestWins": ["noLeak"],
    "policy-allHeads": ["noLeak", "readDuringPartition"],
}
PREDICATES = [
    "visible_dt is assigned in the order records become readable",
    "a shard lets a caller read a file while it holds a concurrent version of the governing policy that denies that caller",
    "LeakA and LeakB never happen",
]

def endpoints(label):
    shard = lambda c: {"A": "shard-a", "B": "shard-b"}.get(c, "shard-a")
    if label == "RestartB": return "shard-b", "shard-b"
    if label.startswith(("Start", "Done", "Fail", "Retry", "Backoff")): return "lanes", "lanes"
    if label.startswith("ImportA"): return "shard-b", "shard-b"
    if label.startswith(("Begin", "Commit")):
        s = shard(label[-2]); return s, s
    if label == "ImportB1": return "shard-b", "shard-a"
    if label == "PullAtoB": return "shard-a", "shard-b"
    if label == "PullBtoA": return "shard-b", "shard-a"
    if label in ("Partition", "Heal"): return "network", "network"
    if label == "FeedPage": return "shard-a", "browser"
    if label in ("Missed", "Synced"): return "observer", "observer"
    if label in ("TightenOnA", "MergeOnA"): return "shard-a", "shard-a"
    if label in ("EditOnB", "MergeOnB"): return "shard-b", "shard-b"
    if label[:-1] in ("Read", "Denied", "Leak"): return shard(label[-1]), "reader"
    return "shard-a", "shard-a"

def trace(task_id, path):
    events, last_by, by_label = [], {}, {}
    for k in range(1, len(path)):
        label = path[k]["message"]
        src, dst = endpoints(label)
        cause = []
        if label.startswith("Commit") and "Begin" + label[6:] in by_label:
            cause = [by_label["Begin" + label[6:]]]
        if label.startswith("Commit") and "Import" + label[6:] in by_label:
            cause = [by_label["Import" + label[6:]]]
        eid = f"e{k}"
        events.append({"id": eid, "task": task_id, "src": src, "dst": dst, "message": label,
                       "prevIds": [last_by[src]] if src in last_by else [], "causeIds": cause})
        last_by[src] = eid
        by_label[label] = eid
    draft = {"id": task_id, "initial": path[0]["state"], "terminals": [],
             "states": sorted({p["state"] for p in path}),
             "transitions": [{"src": path[k - 1]["state"], "dst": path[k]["state"], "message": path[k]["message"]}
                             for k in range(1, len(path))]}
    return {"events": events, "drafts": [draft]}

def main():
    init = mcp.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "island-uploads", "version": "1"}})
    results = {"server": init["serverInfo"], "tools": [t["name"] for t in mcp.rpc("tools/list")["tools"]],
               "explain": {}, "ctl": {}, "traces": {}}
    for name, (say, f0) in FORMULAS.items():
        r, _ = mcp.tool("explain_formula", {"formula": f0})
        results["explain"][name] = {"say": say, "reading": r.get("reading"), "lints": r.get("lints", [])}
    for model, names in ASK.items():
        task = json.load(open(f"{OUT}/{model}.task.json"))
        for name in names:
            r, err = mcp.tool("check_ctl", {"task": task, "formula": FORMULAS[name][1]})
            ev = r.get("evidence") or {}
            entry = {"verdict": r.get("verdict"), "reason": r.get("reason"), "evidence": ev, "isError": err}
            results["ctl"][f"{model}.{name}"] = entry
            path = ev.get("path") or []
            if ev.get("kind") == "counterexample" and len(path) > 1 and name in ("noSkip", "noLeak", "converge", "smallFirst", "xStarts"):
                t, _ = mcp.tool("check_trace", trace(task["id"], path))
                results["traces"][f"{model}.{name}"] = t
            # The server's witness for a nested EF stops at the first conjunct; follow it by asking
            # the remaining formula again from the state where the witness ended.
            f = FORMULAS[name][1]
            while ev.get("kind") == "witness" and "EF" in f and isinstance(f["EF"], dict) and "and" in f["EF"]:
                inner = [x for x in f["EF"]["and"] if "EF" in x]
                if not inner or not path: break
                f = inner[0]
                step = dict(task, initial=path[-1]["state"])
                r2, _ = mcp.tool("check_ctl", {"task": step, "formula": f})
                ev = r2.get("evidence") or {}
                more = ev.get("path") or []
                if r2.get("verdict") != "proved" or len(more) < 2: break
                path = path + more[1:]
                entry["evidence"] = {"kind": "witness", "path": path, "note": "joined from nested EF witnesses"}
            if name == "reverseJump" and len(path) > 1:
                t, _ = mcp.tool("check_trace", trace(task["id"], path))
                results["traces"][f"{model}.{name}"] = t
            print(f"{model:22} {name:20} {entry['verdict']}", flush=True)
    policy = json.load(open(f"{OUT}/policy-allHeads.task.json"))
    r, _ = mcp.tool("classify_requirement", {"task": policy, "predicates": PREDICATES})
    results["classify"] = r
    with open(f"{OUT}/results.json", "w") as f:
        json.dump(results, f, indent=1, sort_keys=True)
        f.write("\n")

if __name__ == "__main__":
    main()
