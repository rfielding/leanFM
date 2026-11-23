"""Turn a whole protocol (sequence, choice, cause, loops, par, sessions and includes) into future-only CTL
and check every formula with LeanFM's session_ctl on the protocol's own state graph. The rules depend on
where a message sits: the next step is only certain outside par (inside, another branch may move first),
an answer is only certain to come outside par (without fairness, another branch may run forever), and a
branch excludes the others only outside loops. Only labels that occur once in the protocol are used to
say what came after what; a label used in many places (RequestRejected) only ever counts as an answer.
Usage (with make serve running): python3 -I translate_full.py <example> <out.json>"""
import json, re, sys, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import translate as T

def tree_of(args):
    ans = T.call("session_explore", args)
    return ans["tree"], ans["lean"]

def build(tree):
    kids = {}
    for n in tree: kids.setdefault(n.get("parent"), []).append(n)
    def body(pid):
        out = []
        for n in kids.get(pid, []):
            k = n["kind"]
            if k == "message":
                m = re.search(r"cause (\w+)", n.get("detail", ""))
                out.append(("msg", n["message"], m.group(1) if m else None))
            elif k == "event": out.append(("act", n["label"].split(" at ")[0]))
            elif k == "choice": out.append(("choice", [body(b["id"]) for b in kids.get(n["id"], []) if b["kind"] == "branch"]))
            elif k == "par": out.append(("par", [body(b["id"]) for b in kids.get(n["id"], []) if b["kind"] == "branch"]))
            elif k == "sessions": out.append(("sessions", body(n["id"])))
            elif k == "include": out.append(("incl", n["label"].split()[1], body(n["id"])))
            elif k == "rec": out.append(("rec", n["label"].split()[1], body(n["id"])))
            elif k == "continue": out.append(("cont", n["label"].split()[1]))
        return out
    return body(0)

def labels(b):
    out = []
    for x in b:
        if x[0] in ("msg", "act"): out.append(x[1])
        elif x[0] in ("choice", "par"): [out.extend(labels(br)) for br in x[1]]
        elif x[0] == "sessions": out.extend(labels(x[1]))
        elif x[0] in ("incl", "rec"): out.extend(labels(x[2]))
    return out

def firsts(b):
    for x in b:
        if x[0] in ("msg", "act"): return {x[1]}
        if x[0] in ("choice", "par"): return set().union(*[firsts(br) for br in x[1]])
        if x[0] == "sessions": return firsts(x[1])
        if x[0] in ("incl", "rec"): return firsts(x[2])
        return set()
    return set()

def ids_of(lean):
    """For each protocol of the text: its message ids, to the label they name."""
    out = {}
    for block in re.split(r"\nprotocol ", lean):
        name = block.split()[0] if block else ""
        out[name] = {i: l for i, l in re.findall(r"(\w+):\s*(\w+)\s+from", block)}
    return out

def translate_full(tree, lean, main):
    top = build(tree)
    count = {}
    for l in labels(top): count[l] = count.get(l, 0) + 1
    uniq = lambda l: count.get(l, 0) == 1
    ids = ids_of(lean)
    out = []
    after, anyof, imp, NOT = T.after, T.anyof, T.imp, T.NOT
    out.append(("start", f"every session starts with {' or '.join(sorted(firsts(top)))}", {"AX": anyof(firsts(top))}))
    # every label that answers each request, over the whole protocol it is written in (its branches too)
    answers = {}
    def collect(b, proto):
        for x in b:
            if x[0] == "msg" and x[2]: answers.setdefault((proto, x[2]), set()).add(x[1])
            elif x[0] in ("choice", "par"): [collect(br, proto) for br in x[1]]
            elif x[0] == "sessions": collect(x[1], proto)
            elif x[0] == "incl": collect(x[2], x[1])
            elif x[0] == "rec": collect(x[2], proto)
    collect(top, main)
    def walk(b, proto, in_par, in_loop):
        for i, x in enumerate(b):
            # every request is answered: outside par, by one of the labels that name it as their cause
            if x[0] == "msg" and not in_par and uniq(x[1]):
                for (pr, rid), rs in answers.items():
                    if pr == proto and ids.get(proto, {}).get(rid) == x[1]:
                        out.append(("cause", f"every {x[1]} is answered ({' or '.join(sorted(rs))})", {"AG": imp(after(x[1]), {"AF": anyof(rs)})}))
            kind = x[0]
            if kind in ("msg", "act") and uniq(x[1]) and i + 1 < len(b):
                nxt = firsts([b[i + 1]])
                if nxt:
                    a = x[1]
                    if not in_par:
                        out.append(("succession", f"after {a} comes {' or '.join(sorted(nxt))}", {"AG": imp(after(a), {"AX": anyof(nxt)})}))
                    for n in sorted(nxt):
                        if uniq(n): out.append(("order", f"no {n} before {a}", NOT({"EU": [NOT(after(a)), after(n)]})))
            if kind == "msg" and x[2]:
                req = ids.get(proto, {}).get(x[2])
                if req and uniq(req) and x[1] != req and uniq(x[1]):
                    out.append(("cause", f"no {x[1]} before its request {req}", NOT({"EU": [NOT(after(req)), after(x[1])]})))
            if kind == "choice":
                brs = x[1]
                if not in_par and not in_loop and len(brs) > 1:
                    for bi, br in enumerate(brs):
                        mine = [l for l in firsts(br) if uniq(l)]
                        others = sorted({l for j, o in enumerate(brs) if j != bi for l in labels(o) if uniq(l)})
                        if mine and others:
                            out.append(("choice", f"after {' or '.join(sorted(mine))}, never {', '.join(others[:3])}{'…' if len(others) > 3 else ''}",
                                        {"AG": imp(anyof(mine), {"AG": NOT(anyof(others))})}))
                for br in brs: walk(br, proto, in_par, in_loop)
            elif kind == "par":
                for br in x[1]: walk(br, proto, True, in_loop)
            elif kind == "sessions": walk(x[1], proto, in_par, in_loop)
            elif kind == "incl": walk(x[2], x[1], in_par, in_loop)
            elif kind == "rec": walk(x[2], proto, in_par, True)
    walk(top, main, False, False)
    for l in sorted(l for l in count if uniq(l)):
        out.append(("possible", f"{l} can happen", {"EF": after(l)}))
    out.append(("end", "from every state, the session can still end", {"AG": {"EF": "terminal"}}))
    # one formula per text: a rule may produce the same one from two places
    seen, uniq_out = set(), []
    for r, n, f in out:
        k = json.dumps(f, sort_keys=True)
        if k not in seen: seen.add(k); uniq_out.append((r, n, f))
    return uniq_out

def show(f):
    """The formula in CTL notation."""
    if isinstance(f, str): return f
    (op, arg), = f.items()
    if op == "after": return arg
    if op == "not": return "¬" + show(arg)
    if op == "or": return "(" + " ∨ ".join(show(a) for a in arg) + ")"
    if op == "implies": return "(" + show(arg[0]) + " → " + show(arg[1]) + ")"
    if op in ("EU", "AU"): return op[0] + "[" + show(arg[0]) + " U " + show(arg[1]) + "]"
    return op + " " + show(arg)

if __name__ == "__main__":
    example, out_path = sys.argv[1], sys.argv[2]
    tree, lean = tree_of({"example": example})
    main = re.search(r"\nprotocol (\w+)[^{]*\{(?![\s\S]*\nprotocol )", lean).group(1)
    fs = translate_full(tree, lean, main)
    t0 = time.time(); res = []
    for r, n, f in fs:
        a = T.call("session_ctl", {"example": example, "formula": f})
        res.append({"rule": r, "name": n, "ctl": show(f), "formula": f, "verdict": a.get("verdict", a.get("error"))})
    dt = time.time() - t0
    from collections import Counter
    print(f"{example}: {len(fs)} formulas in {dt:.1f}s", dict(Counter(x["verdict"] for x in res)), dict(Counter(x["rule"] for x in res)))
    for x in res:
        if x["verdict"] != "proved": print("  NOT PROVED:", x["rule"], x["name"], x["ctl"][:160])
    json.dump({"example": example, "seconds": dt, "formulas": res}, open(out_path, "w"), indent=1)
