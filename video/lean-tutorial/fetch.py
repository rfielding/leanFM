"""Ask Lean and the running LeanFM service (make serve) everything the tutorial video shows, and keep
the answers in data/. Lean: what `lake env lean --json` prints for Tour.lean (every #eval result,
warning and error, by line) and for each file in mistakes/ (each must fail). LeanFM: diagrams,
checks, versions, CTL verdicts, a parsed and formatted formula, a conformance check, and the
requirements gate on the book's Orders example. The codebase counts are measured from the tracked
Lean files. The video draws only these answers. Usage: fetch.py"""
import json, os, re, subprocess, sys
D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
sys.path.insert(0, os.path.join(ROOT, "reports/ctl-translation"))
import translate as T

OUT = os.path.join(D, "data"); os.makedirs(OUT, exist_ok=True)
def save(name, obj): json.dump(obj, open(os.path.join(OUT, name + ".json"), "w"), indent=1, ensure_ascii=False)
def read(rel): return open(os.path.join(ROOT, rel)).read()
def call(tool, args):
    a = T.call(tool, args)
    if a.get("verdict") == "rejected" or ("error" in a and len(a) == 1):
        sys.exit(f"{tool} refused: {json.dumps(a)[:400]}")
    return a

def lean_json(rel):
    """Every message Lean prints for a file, as {line, severity, text}."""
    r = subprocess.run(["lake", "env", "lean", "--json", rel], cwd=ROOT, capture_output=True, text=True)
    msgs = [json.loads(l) for l in r.stdout.splitlines() if l.startswith("{")]
    return r.returncode, [{"line": m["pos"]["line"], "severity": m["severity"], "text": m["data"]} for m in msgs]

# ── Lean ──
code, msgs = lean_json("video/lean-tutorial/Tour.lean")
if code != 0 or any(m["severity"] == "error" for m in msgs): sys.exit(f"Tour.lean does not compile: {msgs}")
save("tour", msgs)

mistakes = {}
for f in sorted(os.listdir(os.path.join(D, "mistakes"))):
    rel = f"video/lean-tutorial/mistakes/{f}"
    code, ms = lean_json(rel)
    errs = [m for m in ms if m["severity"] == "error"]
    if code == 0 or not errs: sys.exit(f"{f} was meant to fail and compiled")
    mistakes[f] = {"source": read(rel), "errors": errs}
save("mistakes", mistakes)

for f in ("Constructs", "Lookup"):
    code, ms = lean_json(f"video/lean-tutorial/protocols/{f}.leanfm")
    if code != 0: sys.exit(f"{f}.leanfm does not elaborate: {ms}")

# the codebase, measured: how LeanFM uses Lean
files = subprocess.run(["git", "ls-files", "*.lean"], cwd=ROOT, capture_output=True, text=True).stdout.split()
files = [f for f in files if not f.startswith(("projects/", "reports/", "video/"))]
text = "\n".join(read(f) for f in files)
count = lambda pat: len(re.findall(pat, text, re.M))
save("stats", {"files": len(files), "lines": text.count("\n"),
               "def": count(r"^\s*(?:@\[[^\]]*\]\s*)?(?:(?:private|protected|partial|noncomputable|unsafe) )*def "),
               "partial def": count(r"partial def "), "Id.run do": count(r"Id\.run do"),
               "structure": count(r"^structure "), "inductive": count(r"^inductive "), "match": count(r"match .* with"),
               "do-arrow": count(r"←|<-"), "#guard": count(r"^#guard"), "theorem": count(r"^\s*(?:private )?theorem "),
               "native_decide": count(r"native_decide"), "boundary": "tracked .lean files outside projects/, reports/ and video/"})

# LeanFM's own grammar for the requirements block, as the syntax scene shows it
g = read("LeanFM/Session/Grammar.lean").splitlines()
start = next(i for i, l in enumerate(g) if l.startswith("def requirementsBody"))
cmd = next(i for i, l in enumerate(g) if "def requirementsCmd" in l)
def definition(i, doc=False):
    """Line i's definition and its indented continuation lines (with its doc comment line if asked)."""
    j = i + 1
    while j < len(g) and g[j][:1].isspace() and g[j].strip(): j += 1
    return g[i - 1 if doc and g[i - 1].lstrip().startswith("/--") else i:j]
save("grammar", {"file": "LeanFM/Session/Grammar.lean", "body": definition(start), "cmd": definition(cmd, doc=True), "line": start + 1})

# ── LeanFM ──
REQ = "examples/orders/Requirements.leanfm"; IMPL = "examples/orders/Implementation.leanfm"
req = read(REQ); proto = req.split("requirements {")[0]
save("orders_text", {"file": REQ, "text": req, "impl_file": IMPL, "impl": read(IMPL)})
save("orders_diagram", {"svg": call("session_diagram", {"lean": proto, "theme": "dark"})["svg"]})
chk = call("session_check", {"lean": proto})
save("orders_check", {k: chk[k] for k in ("verdict", "reading", "roles", "issues", "calls", "callsText") if k in chk})

C = read("video/lean-tutorial/protocols/Constructs.leanfm")
c = call("session_check", {"lean": C})
save("constructs", {"text": C, "verdict": c["verdict"], "reading": c["reading"], "issues": c.get("issues", []),
                    "svg": call("session_diagram", {"lean": C, "theme": "dark"})["svg"]})
L = read("video/lean-tutorial/protocols/Lookup.leanfm")
cp = call("session_compat", {"lean": L}); cp.pop("lean", None)
save("lookup", {"text": L, "compat": cp})

messy = "(AG   (implies (after CreateOrder)\n   (AF (or (after Receipt) (after PaymentDeclined) (after SoldOut)))))"
e = call("explain_formula", {"formula": messy})
save("formula", {"input": messy, **{k: e[k] for k in ("formula", "notation", "reading", "sexpr", "sexprPretty", "lints", "negation")}})

ctl = []
for f in ("(AG (implies (after CreateOrder) (AF (or (after Receipt) (after PaymentDeclined) (after SoldOut)))))",
          "(EF (and (after SoldOut) (EF (after Charge))))"):
    a = call("session_ctl", {"lean": proto, "formula": f})
    ctl.append({"formula": f, "verdict": a["verdict"], "notation": a.get("notation"), "reading": a["reading"],
                "path": a.get("path") or a.get("evidence")})
save("orders_ctl", ctl)

log = json.load(open(os.path.join(ROOT, "examples/orders/logs/order-1.json")))
events = log["events"] if isinstance(log, dict) else log
a = call("session_conform", {"lean": proto, "events": events}); a.pop("diagram", None); a.pop("lean", None)
save("orders_conform", {"log": "examples/orders/logs/order-1.json", "events": events, "verdict": a["verdict"], "reading": a["reading"]})

r = subprocess.run(["lake", "env", "lean", "--run", "LeanFM/RequirementsCheck.lean", "--files", REQ, IMPL],
                   cwd=ROOT, capture_output=True, text=True)
if r.returncode != 0: sys.exit(f"the Orders requirements gate fails; the video shows it passing:\n{r.stdout}{r.stderr}")
save("reqcheck", {"command": f"make requirements-check  (RequirementsCheck --files {REQ} {IMPL})",
                  "exit": r.returncode, "stdout": r.stdout, "stderr": r.stderr})
# each entry's CTL, reading and verdict, as RequirementListsExample.lean wrote them for the book
def listing(rel): return "\n".join(l for l in read(rel).splitlines() if not l.startswith("\\"))
save("orders_explained", {"requirements": listing("book/generated/req-orders-explained.tex"),
                          "implementation": listing("book/generated/req-orders-impl-explained.tex"),
                          "summary": listing("book/generated/req-orders-summary.tex"),
                          "source": "book/generated/req-orders-*.tex (RequirementListsExample.lean)"})
print("saved", sorted(os.listdir(OUT)))
