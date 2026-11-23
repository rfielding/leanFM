"""With prev, every rule has lookahead 0: 'at typestate b, the next typestates are exactly C'. Checking it
needs only the nodes at b and their out-edges, so all the rules together are one forward walk: O(edges)."""
import json, sys, time, resource
from collections import defaultdict
sys.path.insert(0, __file__.rsplit("/", 1)[0]); import faithful as F

def check(d):
    o, s, l = F.model(d); p = F.refine(s, l)
    assert len(p) == 1, "lookahead > 0: a typestate is not named by its last message"
    blk = p[0]
    # the rules: for each typestate (a label), the set of typestates that may follow
    rule = {}
    for v in range(len(o)): rule.setdefault(blk[v], {blk[w] for w in s[v]})
    t0 = time.time()
    bad = []; at = defaultdict(list)
    for v in range(len(o)): at[blk[v]].append(v)            # index: the nodes each rule speaks about
    for b, want in rule.items():
        for v in at[b]:
            got = {blk[w] for w in s[v]}
            if got != want: bad.append((v, b))               # AX (nothing else) and EX (each possible)
    return len(rule), len(o), sum(len(x) for x in s), bad, time.time() - t0

if __name__ == "__main__":
    for g in sys.argv[1:]:
        d = json.load(open(g))["draft"]
        r, n, e, bad, dt = check(d)
        print(f"{g[2:-5]:22} rules {r:6} nodes {n:6} edges {e:6}: {'all proved' if not bad else f'{len(bad)} broken'} in {dt*1000:.0f} ms; peak {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1024:.0f} MB", flush=True)
