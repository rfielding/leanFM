"""Port of Islands.lean replNext, with a choice of what each message says on the wire."""
import json, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0]); import faithful as F, dagcheck as D

def name(r): return f"{r[0].upper()}{r[1]}"

def key(s, feed):
    begun, committed, hA, hB, mAB, mBA, part = s
    srt = lambda xs: tuple(sorted(name(r) for r in xs))
    held = (lambda xs: tuple(name(r) for r in xs)) if feed else srt
    return (srt(begun), srt(committed), held(hA), held(hB), mAB, mBA, part)

def nxt(mode, s, wire):
    begun, committed, hA, hB, mAB, mBA, part = s
    out = []
    for o, ns in (("a", (1, 2)), ("b", (1,))):
        for n in ns:
            r = (o, n)
            if r in begun or r in committed: continue
            if n == 2 and not ((o, 1) in begun or (o, 1) in committed): continue
            out.append((f"Begin{name(r)}", (begun + (r,), committed, hA, hB, mAB, mBA, part)))
    for r in begun:
        if mode == "ordered" and any(x[0] == r[0] and x[1] < r[1] for x in begun): continue
        b2 = tuple(x for x in begun if x != r); c2 = committed + (r,)
        a2, bb2 = (hA + (r,), hB) if r[0] == "a" else (hA, hB + (r,))
        out.append((f"Commit{name(r)}", (b2, c2, a2, bb2, mAB, mBA, part)))
    def pull(src, dst, held_src, held_dst, mark, origin):
        if part: return ("PeerTimedOut" + (f"{src}to{dst}" if "timeout" in wire else ""), None)
        if mode == "cursor":
            fresh = tuple(r for r in held_src[mark:] if r not in held_dst); m2 = len(held_src)
        else:
            fresh = tuple(r for r in committed if r[0] == origin and r[1] > mark and r not in held_dst)
            m2 = max([mark] + [r[1] for r in fresh])
        lab = f"Pull{src}to{dst}"
        if "records" in wire: lab += "[" + ",".join(name(r) for r in fresh) + "]"
        if "cursor" in wire: lab += f"@{m2}"
        return (lab, (fresh, m2))
    l, x = pull("A", "B", hA, hB, mAB, "a")
    out.append((l, s if x is None else (begun, committed, hA, hB + x[0], x[1], mBA, part)))
    l, x = pull("B", "A", hB, hA, mBA, "b")
    out.append((l, s if x is None else (begun, committed, hA + x[0], hB, mAB, x[1], part)))
    out.append(("Heal", (begun, committed, hA, hB, mAB, mBA, False)) if part else ("Partition", (begun, committed, hA, hB, mAB, mBA, True)))
    same = lambda x, y: set(x) == set(y)
    if not begun and same(hA, hB) and same(hA, committed): out.append(("Synced", s))
    return out

def draft(mode, wire):
    init = ((), (), (), (), 0, 0, False); feed = mode == "cursor"
    ids = {key(init, feed): 0}; states = [init]; trans = set(); i = 0
    while i < len(states):
        for lab, t in nxt(mode, states[i], wire):
            k = key(t, feed)
            if k not in ids: ids[k] = len(states); states.append(t)
            trans.add((i, ids[k], lab))
        i += 1
    return {"id": f"repl-{mode}", "initial": "s0", "states": [f"s{j}" for j in range(len(states))], "terminals": [],
            "transitions": [{"src": f"s{a}", "dst": f"s{b}", "message": m} for a, b, m in sorted(trans)]}

if __name__ == "__main__":
    for mode in ("ordered", "unordered", "cursor"):
        for wire in ([], ["timeout"], ["records"], ["records", "cursor"], ["timeout", "records", "cursor"]):
            d = draft(mode, wire)
            o, s, l = F.model(d); p = F.refine(s, l); chi = F.char_formulas(s, l, p); rs = F.rules(s, l, p, chi)
            memo = {}; tree = sum(F.size(f, memo) for _, f in rs)
            S_ = D.Sat(d); ok = all(S_.sat(f)[0] for _, f in rs)
            print(f"{mode:9} {'+'.join(wire) or 'as is':22} states {len(d['states']):4} labels {len({t['message'] for t in d['transitions']}):3} typestates {len(set(p[-1])):4} lookahead {len(p)-1} tree {tree:9.3g} dag {len(memo):6} {'proved' if ok else 'NOT PROVED'}")
            json.dump({"draft": d}, open(f"{__file__.rsplit('/',1)[0]}/g-R_{mode}_{'_'.join(wire) or 'asis'}.json", "w"))
