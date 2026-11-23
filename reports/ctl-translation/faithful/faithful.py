"""Faithful CTL of a protocol's state graph: the characteristic formula up to bisimulation.
Model = the checker's: a node is (state, last message); atoms after(L) and terminal."""
import json, sys
from collections import defaultdict

def model(d):
    term = set(d["terminals"]); out = defaultdict(list)
    for t in d["transitions"]: out[t["src"]].append((t["message"], t["dst"]))
    start = ("s0", None); nodes = {start: 0}; order = [start]; succ = []
    i = 0
    while i < len(order):
        s, last = order[i]; succ.append([])
        if s in term or not out[s]:   # the checker's model: a session that may end stutters there
            succ[i].append(i); i += 1; continue
        for m, dst in out[s]:
            n = (dst, m)
            if n not in nodes: nodes[n] = len(order); order.append(n)
            succ[i].append(nodes[n])
        i += 1
    lab = [(m, s in term) for s, m in order]
    return order, succ, lab

def refine(succ, lab):
    """Partition refinement; parts[k][v] = block of v after k rounds."""
    ids = {}; p = [ids.setdefault(l, len(ids)) for l in lab]; parts = [p]
    while True:
        ids = {}; q = [ids.setdefault((p[v], frozenset(p[w] for w in succ[v])), len(ids)) for v in range(len(p))]
        if len(ids) == len(set(p)): return parts
        parts.append(q); p = q

def char_formulas(succ, lab, parts):
    """chi[k][b]: the depth-k characteristic formula of block b of round k, as a DAG (dict id -> json with refs)."""
    rep = lambda k: {b: v for v, b in reversed(list(enumerate(parts[k])))}
    def atom(l):
        m, t = l
        a = [{"after": m}] if m else [{"not": {"or": [{"after": x} for x in sorted({x for x, _ in lab if x})]}}]
        return {"and": a + [("terminal" if t else {"not": "terminal"})]}
    chi = [{b: atom(lab[v]) for b, v in rep(0).items()}]
    for k in range(1, len(parts)):
        prev = chi[-1]; cur = {}
        for b, v in rep(k).items():
            cs = sorted({parts[k-1][w] for w in succ[v]})
            f = [chi[0][parts[0][v]]] + [{"EX": prev[c]} for c in cs]
            f.append({"AX": {"or": [prev[c] for c in cs]}})
            cur[b] = {"and": f}
        chi.append(cur)
    return chi

def size(f, memo):
    if isinstance(f, str): return 1
    k = id(f)
    if k in memo: return memo[k]
    (op, a), = f.items()
    s = 1 + (sum(size(x, memo) for x in a) if isinstance(a, list) else (1 if op == "after" else size(a, memo)))
    memo[k] = s; return s

def rules(succ, lab, parts, chi):
    """The faithful rule set: start in the initial typestate, and in every typestate exactly its successors are possible."""
    k = len(parts) - 1; K = max(k, 1) if k else 0
    # use round k-1 formulas for successors, round k for the source, all blocks of the final partition
    fin = parts[-1]; out = [("start", chi[-1][fin[0]])]
    seen = set()
    for v in range(len(fin)):
        b = fin[v]
        if b in seen: continue
        seen.add(b)
        cs = sorted({fin[w] for w in succ[v]})
        nxt = [{"EX": chi[-1][c]} for c in cs] + [{"AX": {"or": [chi[-1][c] for c in cs]}}]
        out.append((f"block{b}", {"AG": {"implies": [chi[-1][b], {"and": nxt}]}}))
    return out

if __name__ == "__main__":
    for path in sys.argv[1:]:
        d = json.load(open(path))["draft"]
        order, succ, lab = model(d)
        parts = refine(succ, lab)
        chi = char_formulas(succ, lab, parts)
        rs = rules(succ, lab, parts, chi)
        memo = {}
        tree = sum(size(f, memo) for _, f in rs)
        dag = len(memo)
        print(f"{path.rsplit('/',1)[-1][2:-5]:24} nodes {len(order):6} blocks {len(set(parts[-1])):5} depth {len(parts)-1:3} rules {len(rs):5} formula-tree {tree:.3g} dag {dag}")

def emit(path, out):
    d = json.load(open(path))["draft"]
    order, succ, lab = model(d)
    parts = refine(succ, lab); chi = char_formulas(succ, lab, parts)
    rs = rules(succ, lab, parts, chi)
    json.dump([f for _, f in rs], open(out, "w"), separators=(",", ":"))
    return rs

def show(f):
    """CTL notation."""
    if isinstance(f, str): return {"terminal": "end", "false": "⊥", "true": "⊤"}.get(f, f)
    (op, a), = f.items()
    if op == "after": return a
    if op == "not": return "¬" + show(a)
    if op in ("and", "or"):
        xs = [show(x) for x in a]
        return xs[0] if len(xs) == 1 else "(" + (" ∧ " if op == "and" else " ∨ ").join(xs) + ")"
    if op == "implies": return show(a[0]) + " → " + show(a[1])
    return op + " " + show(a)
