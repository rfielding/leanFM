"""CTL over the checker's model with every shared subformula evaluated once (a DAG, not a tree)."""
import json, sys, time
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0]); import faithful as F

class Sat:
    def __init__(self, d):
        self.order, succ, self.lab = F.model(d)
        self.n = len(self.order)
        self.src = np.array([v for v, ws in enumerate(succ) for _ in ws]); self.dst = np.array([w for ws in succ for w in ws])
        self.memo = {}
    def ex(self, a):
        r = np.zeros(self.n, bool); np.logical_or.at(r, self.src, a[self.dst]); return r
    def ax(self, a):
        bad = np.zeros(self.n, bool); np.logical_or.at(bad, self.src, ~a[self.dst]); return ~bad
    def sat(self, f):
        if isinstance(f, str):
            if f == "terminal": return np.array([t for _, t in self.lab])
            return np.full(self.n, f == "true")
        k = id(f)
        if k in self.memo: return self.memo[k][1]
        (op, a), = f.items()
        if op == "after": r = np.array([m == a for m, _ in self.lab])
        elif op == "not": r = ~self.sat(a)
        elif op == "and": r = np.logical_and.reduce([self.sat(x) for x in a]) if a else np.ones(self.n, bool)
        elif op == "or": r = np.logical_or.reduce([self.sat(x) for x in a]) if a else np.zeros(self.n, bool)
        elif op == "implies": r = ~self.sat(a[0]) | self.sat(a[1])
        elif op == "EX": r = self.ex(self.sat(a))
        elif op == "AX": r = self.ax(self.sat(a))
        elif op == "AG":
            p = self.sat(a); z = p.copy()
            while True:
                z2 = p & self.ax(z)
                if (z2 == z).all(): break
                z = z2
            r = z
        else: raise ValueError(op)
        self.memo[k] = (f, r); return r

if __name__ == "__main__":
    g = sys.argv[1]
    d = json.load(open(g))["draft"]
    t0 = time.time(); o, s, l = F.model(d); p = F.refine(s, l); chi = F.char_formulas(s, l, p); rs = F.rules(s, l, p, chi); t1 = time.time()
    S_ = Sat(d); res = [bool(S_.sat(f)[0]) for _, f in rs]; t2 = time.time()
    print(f"{g[2:-5]:22} {len(rs)} rules: {sum(res)} proved, {len(res)-sum(res)} disproved; build {t1-t0:.2f}s, check {t2-t1:.2f}s, {len(S_.memo)} distinct subformulas")
