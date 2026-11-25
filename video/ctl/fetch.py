"""Ask the running LeanFM service (make serve) everything the CTL video shows, and keep the answers in
data/: generated diagrams, a flat log separated into sessions, every formula reports/ctl-translation
derives with session_ctl's verdict on the protocol and on each broken variant, and measured timings.
The video draws only these answers. Usage: fetch.py"""
import json, os, re, sys, time
D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
sys.path.insert(0, os.path.join(ROOT, "reports/ctl-translation"))
import translate as T

OUT = os.path.join(D, "data"); os.makedirs(OUT, exist_ok=True)
def save(name, obj): json.dump(obj, open(os.path.join(OUT, name + ".json"), "w"), indent=1)

cases = json.load(open(os.path.join(ROOT, "reports/ctl-translation/cases.json")))
orders, place = cases[0]["lean"], cases[1]["lean"]
save("orders_diagram", T.call("session_diagram", {"lean": orders}))
save("place_diagram", T.call("session_diagram", {"lean": place}))
save("place_check", T.call("session_check", {"lean": place}))
# the envelope every logged message carries (id, prev, cause), as LeanFM writes it
save("orders_types", T.call("session_types", {"lean": orders}))
# GoServer's move: its where clause implements the cause on the wire
gs = open(os.path.join(ROOT, "projects/GoServer/source/cmd/demo/static/session/goserver.leanfm")).read()
save("goserver_playmove", {"text": re.search(r"protocol PlayMoveP.*?\n}\n", gs, re.S).group(0), "source": "projects/GoServer/source/cmd/demo/static/session/goserver.leanfm"})
# a flat log: three orders interleaved, no session ids (the sessions video's log)
flat = json.load(open(os.path.join(ROOT, "video/sessions/data/orders_three.json")))
save("orders_flat", T.call("session_conform", {"lean": orders, "events": flat["arguments"]["events"]}) | {"events_in": flat["arguments"]["events"]})

# the translation: every formula, its verdict on the protocol, and on each broken variant
trans = {}
for c in cases:
    fs = T.translate(c["lean"])
    own = T.check(c["lean"], fs)
    variants = []
    for v in c["variants"]:
        got = T.check(v["lean"], fs)
        variants.append({"name": v["name"], "lean": v["lean"], "verdicts": [x[2] for x in got]})
    trans[c["name"]] = {"formulas": [{"rule": r, "name": n, "formula": f, "verdict": x[2]} for (r, n, f), x in zip(fs, own)],
                        "variants": variants}
save("translation", trans)

# timings, measured on this machine against the running service
def timed(tool, args, reps=3):
    best = 1e9; ans = None
    for _ in range(reps):
        t = time.time(); ans = T.call(tool, args); best = min(best, time.time() - t)
    return best, ans
fsP = T.translate(place)
t0 = time.time(); T.check(place, fsP); tp = time.time() - t0
tg, ag = timed("session_ctl", {"example": "goserver", "formula": {"EF": {"on": "PlayMove"}}})
tparse, _ = timed("session_check", {"example": "goserver"})
tsug, asug = timed("session_ctl", {"example": "goserver"})
save("timings", {"place_formulas": len(fsP), "place_seconds": tp,
                 "goserver_states": ag.get("states"), "goserver_one_formula_s": tg,
                 "goserver_parse_s": tparse, "goserver_batch_s": tsug, "goserver_batch_n": len(asug.get("suggestions", []))})
print("saved", sorted(os.listdir(OUT)))
