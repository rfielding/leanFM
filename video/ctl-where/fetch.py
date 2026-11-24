"""Ask the running LeanFM service (make serve) everything the CTL-and-where video shows, and keep the
answers in data/: diagrams, faithful rules, a faithfulness comparison, CTL verdicts with and without
field atoms, and session_conform on logs whose values keep or break each where clause. The refinement
rounds come from Typestates.lean (LeanFM's own Faithful.typestates). The video draws only these
answers. Usage: fetch.py"""
import json, os, subprocess, sys, time
D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
sys.path.insert(0, os.path.join(ROOT, "reports/ctl-translation"))
import translate as T

OUT = os.path.join(D, "data"); os.makedirs(OUT, exist_ok=True)
def save(name, obj): json.dump(obj, open(os.path.join(OUT, name + ".json"), "w"), indent=1)
def text(name): return open(os.path.join(D, "protocols", name + ".leanfm")).read()
def call(tool, args):
    a = T.call(tool, args)
    if "error" in a and len(a) == 1: sys.exit(f"{tool} refused: {a['error'][:300]}")
    a.pop("diagram", None)  # the conform drawing is large and the video does not use it
    return a

P = {n: text(n) for n in ("Upload", "PlaceOrder", "Images", "Pricing", "PricingGap")}

# the typestates and refinement rounds, from LeanFM's Faithful module
subprocess.run(["lake", "env", "lean", "--run", os.path.join(D, "Typestates.lean"), os.path.join(OUT, "typestates.json")] +
               [f"{n}={os.path.join(D, 'protocols', n + '.leanfm')}" for n in ("Upload", "PlaceOrder", "Images", "Pricing")],
               cwd=ROOT, check=True)

for n in ("Upload", "PlaceOrder", "Images", "Pricing"):
    save(f"diagram_{n}", {"svg": call("session_diagram", {"lean": P[n]})["svg"]})
for n in ("Images", "Upload", "PlaceOrder"):
    save(f"rules_{n}", call("session_ctl", {"lean": P[n], "faithful": "rules"}))

# faithfulness: PlaceOrder against a copy that can no longer say SoldOut
no_sold_out = P["PlaceOrder"].replace("  } or {\n    SoldOut from Shop to Client cause o status 409;\n  }\n", "  }\n").replace("  choice {\n    q: Quote", "  {\n    q: Quote")
variant = P["PlaceOrder"].replace("SoldOut from Shop to Client cause o status 409;", "Backorder from Shop to Client cause o status 202;")
t0 = time.time(); cmp = call("session_ctl", {"lean": P["PlaceOrder"], "faithful": {"lean": variant}}); tc = time.time() - t0
save("faithful_compare", {"variant": "SoldOut 409 replaced by Backorder 202", "answer": cmp, "seconds": tc})

# the model holds labels, not values: a field atom is unknown, a guard's branches are both possible
save("field_atom", call("session_ctl", {"lean": P["PlaceOrder"], "formula":
     {"AG": {"implies": [{"after": "Pay"}, {"field": {"message": "Pay", "name": "amount", "value": "10"}}]}}}))
save("pricing_ctl", [{"formula": f, "answer": call("session_ctl", {"lean": P["Pricing"], "formula": f})}
                     for f in ("(EF (after Discount))", "(EF (after Quote))", "(AG (implies (after Discount) (AG (not (after Quote)))))")])

def ev(i, label, src, dst, cause=None, body=None):
    e = {"id": i, "label": label, "from": src, "to": dst}
    if cause: e["cause"] = cause
    if body is not None: e["body"] = body
    return e
def conform(name, lean, events): return {"name": name, "events": events, "answer": call("session_conform", {"lean": lean, "events": events})}

save("pricing_conform", [
    conform("total 150, Discount", P["Pricing"], [ev("o1", "CreateOrder", "Client", "Shop", body={"total": 150}), ev("d1", "Discount", "Shop", "Client", "o1", {"percent": 10})]),
    conform("total 50, Discount", P["Pricing"], [ev("o1", "CreateOrder", "Client", "Shop", body={"total": 50}), ev("d1", "Discount", "Shop", "Client", "o1", {"percent": 10})]),
    conform("total not logged", P["Pricing"], [ev("o1", "CreateOrder", "Client", "Shop"), ev("d1", "Discount", "Shop", "Client", "o1", {"percent": 10})]),
    conform("gap: total 70, Quote", P["PricingGap"], [ev("o1", "CreateOrder", "Client", "Shop", body={"total": 70}), ev("q1", "Quote", "Shop", "Client", "o1")]),
    conform("gap: total 70, Discount", P["PricingGap"], [ev("o1", "CreateOrder", "Client", "Shop", body={"total": 70}), ev("d1", "Discount", "Shop", "Client", "o1", {"percent": 10})])])
save("pricing_gap_ctl", call("session_ctl", {"lean": P["PricingGap"], "formula": "(AF terminal)"}))

good = [ev("o1", "CreateOrder", "Client", "Shop", body={"item": "tea", "quantity": 1}), ev("q1", "Quote", "Shop", "Client", "o1", {"price": 10}),
        ev("p1", "Pay", "Client", "Shop", "q1", {"amount": 10}), ev("c1", "Charge", "Shop", "Bank", "p1", {"amount": 10}),
        ev("d1", "Charged", "Bank", "Shop", "c1"), ev("r1", "Receipt", "Shop", "Client", "d1", {"amount": 10})]
bad = [dict(e) for e in good]; bad[2] = dict(bad[2], body={"amount": 12})
save("place_conform", [conform("amount 10, price 10", P["PlaceOrder"], good), conform("amount 12, price 10", P["PlaceOrder"], bad)])

size_log = [{"id": "a1", "from": "Browser", "to": "Server", "label": "GetImage", "fields": {"id": "cat"}},
            {"id": "a2", "from": "Server", "to": "Browser", "label": "Image", "cause": "a1",
             "fields": {"imageId": "cat", "contentLength": "48213", "cacheControl": "no-store", "size": "48000"}}]
save("images_conform", conform("Content-Length 48213, body 48000 bytes", P["Images"], size_log))

# identity: a flat log with no session ids, untangled by the Fresh/Link equation on orderId
cases = json.load(open(os.path.join(ROOT, "reports/ctl-translation/cases.json")))
orders = cases[0]["lean"]
flat = json.load(open(os.path.join(ROOT, "video/sessions/data/orders_three.json")))["arguments"]["events"]
save("orders_flat", {"lean": orders, "events": flat, "answer": call("session_conform", {"lean": orders, "events": flat})})

# timings on this machine
def timed(tool, args, reps=3):
    best = 1e9
    for _ in range(reps):
        t = time.time(); call(tool, args); best = min(best, time.time() - t)
    return best
save("timings", {"goserver_rules_s": timed("session_ctl", {"example": "goserver", "faithful": "rules"}),
                 "goserver_rules": call("session_ctl", {"example": "goserver", "faithful": "rules"}).get("ruleCount"),
                 "placeorder_compare_s": tc})
print("saved", sorted(os.listdir(OUT)))
