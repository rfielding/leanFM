import json, sys, random, copy
sys.path.insert(0, __file__.rsplit("/",1)[0]); import faithful as F
def bisim(d1, d2):
    """Are the two drafts' checker models bisimilar? (disjoint union, partition refinement)"""
    o1, s1, l1 = F.model(d1); o2, s2, l2 = F.model(d2)
    n = len(o1); succ = s1 + [[w + n for w in ws] for ws in s2]; lab = l1 + l2
    p = F.refine(succ, lab)[-1]
    return p[0] == p[n]
def mutants(d, rng, k=40):
    T = d["transitions"]; out = []
    labels = sorted({t["message"] for t in T}); states = d["states"]
    for i in range(len(T)):                      # drop one step (say, the 404 branch)
        m = copy.deepcopy(d); del m["transitions"][i]; out.append(("drop " + T[i]["message"], m))
    for _ in range(k):                           # allow a step where the protocol does not
        t = dict(rng.choice(T)); t["src"] = rng.choice(states); t["dst"] = rng.choice(states)
        m = copy.deepcopy(d); m["transitions"].append(t); out.append(("add " + t["message"], m))
    for _ in range(k):                           # send a step to the wrong next typestate
        m = copy.deepcopy(d); i = rng.randrange(len(T)); m["transitions"][i]["dst"] = rng.choice(states)
        out.append(("retarget " + T[i]["message"], m))
    for _ in range(k // 2):                      # relabel a step (a 500 instead of a 404)
        m = copy.deepcopy(d); i = rng.randrange(len(T)); m["transitions"][i]["message"] = rng.choice(labels)
        out.append(("relabel " + T[i]["message"], m))
    return out
if __name__ == "__main__":
    g, outm, outk = sys.argv[1:4]
    d = json.load(open(g))["draft"]; ms = mutants(d, random.Random(7))
    kinds = [(k, bisim(d, m)) for k, m in ms]
    json.dump([m for _, m in ms], open(outm, "w")); json.dump(kinds, open(outk, "w"))
