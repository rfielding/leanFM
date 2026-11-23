"""Ask the running LeanFM service (make serve) every question the sessions video shows, and keep the
answers in data/: the video draws only these answers (protocol text, diagrams, derived sessions,
problems and notes), never a hand-drawn substitute. Usage: fetch.py [url]"""
import json, os, re, sys, urllib.request

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080/mcp"
OUT = os.path.join(D, "data"); os.makedirs(OUT, exist_ok=True)

src = open(os.path.join(ROOT, "LeanFM/Session/IdentityTests.lean")).read()
def fixture(name):  # the protocol texts are the identity tests' own fixtures
    return re.search(rf'def {name} := "(.*?)"\n', src, re.S).group(1).replace('\\"', '"')
ORDERS, SITE = fixture("orders"), fixture("site")
LEND = "protocol Lend (M, D) { sessions { b: Borrow from M to D; Lent from D to M cause b; Return from M to D; } }"

def call(tool, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}})
    req = urllib.request.Request(URL, body.encode(), {"content-type": "application/json", "accept": "application/json, text/event-stream"})
    r = json.load(urllib.request.urlopen(req))["result"]
    return {"text": r["content"][0]["text"], "result": r.get("structuredContent")}

def ev(id, label, src, dst, cause=None, **parts):
    e = {"id": id, "label": label, "from": src, "to": dst}
    if cause: e["cause"] = cause
    e.update(parts); return e
# Orders: a session is minted by Created (orderId Fresh) and named by GetOrder (orderId Link)
create = lambda i: ev(i, "CreateOrder", "Client", "Api", body={"item": "tea"})
created = lambda i, c, o: ev(i, "Created", "Api", "Client", c, headers={"orderId": o})
get = lambda i, o: ev(i, "GetOrder", "Client", "Api", path={"orderId": o}, query={"verbose": False})
order = lambda i, c, o: ev(i, "Order", "Api", "Client", c, body={"orderId": o, "item": "tea"})
# Site: Login mints sid; every Order task is given it as token
def C(i, l, c=None, **p): return ev(i, l, "Client", "Shop", c, **p)
def S(i, l, c=None, **p): return ev(i, l, "Shop", "Client", c, **p)
login = lambda n, s: [C(f"l{n}", "Login", body={"user": "u"}), S(f"i{n}", "LoggedIn", f"l{n}", headers={"sid": s})]
logout = lambda n, s: [C(f"x{n}", "Logout", headers={"sid": s}), S(f"b{n}", "Bye", f"x{n}")]

questions = {
  "orders_diagram": ("session_diagram", {"lean": ORDERS}),
  "orders_three": ("session_conform", {"lean": ORDERS, "events": [
      create("c1"), create("c2"), created("k2", "c2", "o2"), create("c3"), created("k1", "c1", "o1"),
      get("g2", "o2"), created("k3", "c3", "o3"), get("g1", "o1"), order("r2", "g2", "o2"),
      get("g3", "o3"), order("r1", "g1", "o1"), order("r3", "g3", "o3")]}),
  "orders_remint": ("session_conform", {"lean": ORDERS, "allowIncomplete": True, "events": [
      create("c1"), created("k1", "c1", "o7"), create("c2"), created("k2", "c2", "o7")]}),
  "orders_reuse": ("session_conform", {"lean": ORDERS, "events": [
      create("c1"), created("k1", "c1", "o7"), get("g1", "o7"), order("r1", "g1", "o7"),
      create("c2"), created("k2", "c2", "o7"), get("g2", "o7"), order("r2", "g2", "o7")]}),
  # one server thread Api/a1 serves two orders in turn: its prev chain runs through both sessions
  "orders_served": ("session_conform", {"lean": ORDERS, "events": [
      dict(create("c1"), **{"from": "Client/c1", "to": "Api/a1"}),
      dict(create("c2"), **{"from": "Client/c2", "to": "Api/a1"}),
      dict(created("k1", "c1", "o1"), **{"from": "Api/a1", "to": "Client/c1"}),
      dict(created("k2", "c2", "o2"), **{"from": "Api/a1", "to": "Client/c2", "prev": "k1"}),
      dict(get("g2", "o2"), **{"from": "Client/c2", "to": "Api/a1", "prev": "c2"}),
      dict(get("g1", "o1"), **{"from": "Client/c1", "to": "Api/a1", "prev": "c1"}),
      dict(order("r2", "g2", "o2"), **{"from": "Api/a1", "to": "Client/c2", "prev": "k2"}),
      dict(order("r1", "g1", "o1"), **{"from": "Api/a1", "to": "Client/c1", "prev": "r2"})]}),
  "site_check": ("session_check", {"lean": SITE}),
  "site_diagram": ("session_diagram", {"lean": SITE}),
  "site_unbound": ("session_check", {"lean": SITE.replace(" with token = sid;", ";")}),
  "site_two": ("session_conform", {"lean": SITE, "events":
      login("1", "s1") + login("2", "s2") +
      [C("c1", "Create", headers={"token": "s1"}, body={"item": "tea"}),
       C("c2", "Create", headers={"token": "s2"}, body={"item": "tea"}),
       S("m2", "Made", "c2", headers={"token": "s2"}, body={"orderId": "o2"}),
       S("m1", "Made", "c1", headers={"token": "s1"}, body={"orderId": "o1"}),
       C("g1", "Get", headers={"token": "s1"}, path={"orderId": "o1"}),
       C("g2", "Get", headers={"token": "s2"}, path={"orderId": "o2"}),
       S("t2", "Got", "g2", body={"orderId": "o2"}),
       S("t1", "Got", "g1", body={"orderId": "o1"})] +
      logout("1", "s1") + logout("2", "s2")}),
  "site_cross": ("session_conform", {"lean": SITE, "allowIncomplete": True, "events":
      login("1", "s1") + login("2", "s2") +
      [C("c1", "Create", headers={"token": "s1"}, body={"item": "tea"}),
       S("m1", "Made", "c1", headers={"token": "s1"}, body={"orderId": "o1"}),
       C("gx", "Get", headers={"token": "s2"}, path={"orderId": "o1"})]}),
  "lend_check": ("session_check", {"lean": LEND}),
}
for name, (tool, args) in questions.items():
    a = call(tool, args)
    json.dump({"tool": tool, "arguments": args, **a}, open(os.path.join(OUT, f"{name}.json"), "w"), indent=1)
    print(f"{name}: {a['text'][:150]}")
