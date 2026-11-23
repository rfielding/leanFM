"""Per-actor atoms: a node remembers the last message at each actor, not one global last message."""
import json, sys, glob
sys.path.insert(0, __file__.rsplit("/", 1)[0]); import faithful as F
from collections import defaultdict

def actors_of(m):
    if m.startswith(("BeginA", "CommitA")): return ("a",)
    if m.startswith(("BeginB", "CommitB")): return ("b",)
    if m.startswith("PullAtoB"): return ("b",)          # b stores what a served
    if m.startswith("PullBtoA"): return ("a",)
    if m.startswith("PeerTimedOut"): return ("a", "b") if m == "PeerTimedOut" else (("b",) if "AtoB" in m else ("a",))
    if m in ("Partition", "Heal"): return ("net",)
    if m == "Synced": return ("obs",)
    raise ValueError(m)
ACT = ("a", "b", "net", "obs")

def model(d):
    out = defaultdict(list)
    for t in d["transitions"]: out[t["src"]].append((t["message"], t["dst"]))
    start = ("s0", (None,) * len(ACT)); nodes = {start: 0}; order = [start]; succ = []; i = 0
    while i < len(order):
        s, last = order[i]; succ.append([])
        for m, dst in out[s]:
            l2 = tuple(m if a in actors_of(m) else x for a, x in zip(ACT, last))
            n = (dst, l2)
            if n not in nodes: nodes[n] = len(order); order.append(n)
            succ[i].append(nodes[n])
        i += 1
    return order, succ, [last for _, last in order]

if __name__ == "__main__":
    for g in sys.argv[1:]:
        d = json.load(open(g))["draft"]
        o, s, l = model(d); p = F.refine(s, l)
        print(f"{g[4:-5]:36} nodes {len(o):5} typestates {len(set(p[-1])):5} lookahead {len(p)-1}")
