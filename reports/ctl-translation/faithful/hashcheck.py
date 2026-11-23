"""Memory-light CTL check: subformulas keyed by a hash of their canonical text (hash-consing),
truth sets kept only while the rule that needs them is open, atoms computed from integer label ids."""
import json, sys, time, hashlib, resource
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0]); import faithful as F

class Checker:
    def __init__(self, d):
        order, succ, lab = F.model(d)
        self.n = len(order)
        names = {}; self.lab = np.array([names.setdefault(m, len(names)) for m, _ in lab]); self.names = names
        self.term = np.array([t for _, t in lab])
        self.src = np.array([v for v, ws in enumerate(succ) for _ in ws]); self.dst = np.array([w for ws in succ for w in ws])
        self.hits = self.misses = 0
    def key(self, f): return hashlib.blake2b(json.dumps(f, sort_keys=True, separators=(",", ":")).encode(), digest_size=16).digest()
    def ex(self, a): r = np.zeros(self.n, bool); np.logical_or.at(r, self.src, a[self.dst]); return r
    def ax(self, a): b = np.zeros(self.n, bool); np.logical_or.at(b, self.src, ~a[self.dst]); return ~b
    def sat(self, f, memo):
        if isinstance(f, str): return self.term.copy() if f == "terminal" else np.full(self.n, f == "true")
        k = self.key(f)
        if k in memo: self.hits += 1; return memo[k]
        self.misses += 1
        (op, a), = f.items()
        if op == "after": r = self.lab == self.names.get(a, -1)
        elif op == "not": r = ~self.sat(a, memo)
        elif op == "and":
            r = np.ones(self.n, bool)
            for x in a: r &= self.sat(x, memo)
        elif op == "or" and all(isinstance(x, dict) and "after" in x for x in a):
            r = np.isin(self.lab, [self.names.get(x["after"], -1) for x in a])
        elif op == "or":
            r = np.zeros(self.n, bool)
            for x in a: r |= self.sat(x, memo)
        elif op == "implies": r = ~self.sat(a[0], memo) | self.sat(a[1], memo)
        elif op == "EX": r = self.ex(self.sat(a, memo))
        elif op == "AX": r = self.ax(self.sat(a, memo))
        elif op == "AG":
            # every node of the model is reachable from the start, so AG at the start is "everywhere"
            r = np.full(self.n, bool(self.sat(a, memo).all()))
        else: raise ValueError(op)
        memo[k] = r; return r

if __name__ == "__main__":
    for g in sys.argv[1:]:
        d = json.load(open(g))["draft"]
        t0 = time.time(); o, s, l = F.model(d); p = F.refine(s, l); chi = F.char_formulas(s, l, p); rs = F.rules(s, l, p, chi); t1 = time.time()
        C = Checker(d); ok = 0
        for _, f in rs:
            memo = {}                       # one rule's subformulas; dropped when the rule is decided
            ok += bool(C.sat(f, memo)[0])
        t2 = time.time()
        mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
        print(f"{g[2:-5]:24} nodes {C.n:6} lookahead {len(p)-1} rules {len(rs):6}: {ok} proved; build {t1-t0:.1f}s check {t2-t1:.1f}s; peak {mb:.0f} MB; hash hits {C.hits} misses {C.misses}", flush=True)
