"""Diagrams into CTL in depth, and where clauses: narrated and scored. Every diagram, typestate class,
rule, verdict, log reading and timing on screen is read from data/, which fetch.py asked the running
LeanFM service (and Typestates.lean asked LeanFM's Faithful module); nothing is drawn by hand. dot only
places the boxes. Usage: produce.py [out.mp4]"""
import json, os, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data")
WORK = os.path.join(D, "build"); os.makedirs(WORK, exist_ok=True)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "leanfm-ctl-and-where.mp4")
PIPER = f"{ROOT}/video/.conda/bin/piper"
VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
SCORE_DIR = f"{ROOT}/projects/Maqam/impl/zig/source"
SCORE = "synth.mq"
FPS, W, H = 30, 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85); HEAD = (32, 40, 54)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184)
RED = (248, 113, 113); BLUE = (125, 175, 255); VIOLET = (196, 160, 255); PINK = (244, 114, 182); CYAN = (34, 211, 238)
CLASS = ["#334155", "#1d4ed8", "#047857", "#b45309", "#7c3aed", "#be185d", "#0e7490", "#4d7c0f", "#9f1239", "#6d28d9"]
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_fonts = {}
def F(p, s):
    if (p, s) not in _fonts: _fonts[p, s] = ImageFont.truetype(p, s)
    return _fonts[p, s]
def run(cmd, **kw): subprocess.run(cmd, check=True, **kw)
def load(name): return json.load(open(os.path.join(DATA, f"{name}.json")))
def proto(name): return open(os.path.join(D, "protocols", f"{name}.leanfm")).read()

TS = load("typestates")
RULES = {n: load(f"rules_{n}") for n in ("Images", "Upload", "PlaceOrder")}
CMP = load("faithful_compare"); FIELD = load("field_atom"); PCTL = load("pricing_ctl"); PCON = load("pricing_conform")
GAP = load("pricing_gap_ctl"); PLACE = load("place_conform"); IMG = load("images_conform"); FLAT = load("orders_flat"); TIM = load("timings")

# sequence diagrams, drawn by session_diagram
for n in ("Images", "Upload", "PlaceOrder", "Pricing"):
    svg = os.path.join(WORK, f"seq_{n}.svg"); open(svg, "w").write(load(f"diagram_{n}")["svg"])
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-width", "1400", "-i", svg, os.path.join(WORK, f"seq_{n}.png")])

def graph_png(name, rnd=None, path=None, rankdir="LR"):
    """The checker model of `name`, a box per node named by its last message (double border where the
    session may end, a loop for the stutter). With rnd, each node is filled by its class in that
    refinement round, so nodes the round cannot tell apart share a colour."""
    t = TS[name]; ink = "#e8e8eb"
    out = [f'digraph T {{ rankdir={rankdir}; bgcolor="#0d1117"; nodesep=0.3; ranksep=0.5; margin=0.15; dpi=150;',
           f'node [shape=box, style="rounded,filled", color="{ink}", fillcolor="#22242a", fontcolor="{ink}", fontname="DejaVu Sans", fontsize=13, penwidth=1.4, height=0.4];',
           f'edge [color="{ink}", arrowsize=0.7, penwidth=1.3]; s [shape=point, width=0.1, color="{ink}"]; s -> n0;']
    rounds = t["rounds"]
    for i, nd in enumerate(t["nodes"]):
        fill = f', fillcolor="{CLASS[rounds[rnd][i] % len(CLASS)]}"' if rnd is not None else ""
        out.append(f'n{i} [label="{nd["message"] or "start"}"{", peripheries=2" if nd["ends"] else ""}{fill}];')
    for i, ss in enumerate(t["succ"]):
        for j in ss: out.append(f"n{i} -> n{j};")
    out.append("}")
    dot = os.path.join(WORK, f"{path or name}.dot"); png = os.path.join(WORK, f"{path or name}.png")
    open(dot, "w").write("\n".join(out)); run(["dot", "-Tpng", dot, "-o", png])
    return png

# ── drawing ──
def base(tag, title=None, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN)
    d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    if title: d.text((80, 112), title, font=F(B, 50), fill=TEXT)
    if sub: d.text((80, 182), sub, font=F(R, 28), fill=AMBER)
    return img, d

KW = {"protocol", "structure", "where", "from", "to", "cause", "choice", "or", "route", "status", "media", "and", "not", "implies", "AG", "AX", "EX", "AF", "EF"}
def code(d, x, y, w, h, head, lines, size=22, color=GREEN, mark=()):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=EDGE, width=2)
    d.rounded_rectangle([x, y, x + w, y + 52], radius=14, fill=HEAD); d.rectangle([x, y + 38, x + w, y + 52], fill=HEAD)
    d.text((x + 22, y + 12), head, font=F(B, 24), fill=color)
    f = F(M, size); lh = int(size * 1.4); yy = y + 68
    for line in lines:
        if any(m in line for m in mark): d.rectangle([x + 4, yy - 3, x + w - 4, yy + lh - 5], fill=(22, 58, 46))
        cx, tok = x + 22, ""
        for ch in line + " ":
            if ch.isalnum() or ch == "_": tok += ch; continue
            if tok:
                d.text((cx, yy), tok, font=f, fill=BLUE if tok in KW else TEXT)
                cx += f.getlength(tok); tok = ""
            d.text((cx, yy), ch, font=f, fill=AMBER if ch in "#=<>" else TEXT); cx += f.getlength(ch)
        yy += lh

def paste_fit(img, path, box, frame=True):
    src = Image.open(path).convert("RGBA")
    im = Image.new("RGB", src.size, BG); im.paste(src, (0, 0), src)
    bw, bh = box[2] - box[0], box[3] - box[1]
    s = min(bw / im.width, bh / im.height, 1.6)
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    x = box[0] + (bw - im.width) // 2; y = box[1] + (bh - im.height) // 2
    img.paste(im, (x, y))
    if frame: ImageDraw.Draw(img).rectangle([x - 1, y - 1, x + im.width, y + im.height], outline=EDGE, width=2)

def wrap(d, x, y, text, font, width, fill, gap=8):
    line = ""
    for wd in text.split():
        t = (line + " " + wd).strip()
        if d.textlength(t, font=font) > width and line:
            d.text((x, y), line, font=font, fill=fill); y += font.size + gap; line = wd
        else: line = t
    if line: d.text((x, y), line, font=font, fill=fill); y += font.size + gap
    return y

def box(d, x, y, w, h, color, title, body, size=26, mono=False):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=color, width=3)
    d.text((x + 22, y + 16), title, font=F(B, 30), fill=color)
    return wrap(d, x + 22, y + 66, body, F(M if mono else R, size), w - 44, TEXT)

def chunks(s, n):
    out, line = [], ""
    for wd in s.split(" "):
        if len(line) + len(wd) + 1 > n and line: out.append(line); line = wd
        else: line = (line + " " + wd).strip()
    return out + ([line] if line else [])

def event_part(issue):
    """An issue without its session prefix: from the event on."""
    i = issue.find("event ")
    return issue[i:] if i >= 0 else issue

def verdict_color(v): return GREEN if v in ("proved", "conforms", "faithful") else RED if v in ("disproved", "violates", "unfaithful") else AMBER

# ── scenes ──
scenes = []
def scene(id, text, animated=False):
    def deco(fn): scenes.append((id, text, fn, animated)); return fn
    return deco

@scene("title", "This is the deep version. How LeanFM turns an interaction diagram into C T L, formula by formula, "
       "why those formulas say exactly what the diagram says and nothing more, and then the part a diagram cannot show: "
       "where clauses, the conditions on the data the messages carry. How the two fit together, and where they don't.")
def _(p):
    img, d = base("LEANFM · CTL AND WHERE CLAUSES")
    d.text((80, 280), "From a diagram to CTL,", font=F(B, 88), fill=TEXT)
    d.text((80, 390), "and where the data comes in", font=F(B, 88), fill=TEXT)
    for i, (k, c, t) in enumerate([("the shape", GREEN, "state graph, typestates, faithful rules: decided by a model checker"),
                                   ("the values", AMBER, "where clauses: run over the data each message carries"),
                                   ("together", PINK, "what a run must satisfy, and what carries over")]):
        d.text((120, 560 + i * 70), k, font=F(B, 34), fill=c); d.text((420, 560 + i * 70), t, font=F(R, 32), fill=TEXT)
    d.text((80, 960), "every diagram, rule, verdict and log reading below is a LeanFM answer (video/ctl-where/data)", font=F(R, 24), fill=MUTED)
    img.save(p)

@scene("model", "Start with the smallest protocol. A browser asks for an image; the server answers with the image, or with not found. "
       "LeanFM turns the diagram into a state graph. Each node is a moment of the conversation, labelled by one fact: the message "
       "that just happened. Two atoms are all C T L sees here: after, naming that message, and terminal, saying the conversation may stop. "
       "An ended conversation repeats itself forever, a loop, so every path is infinite and the logic has no edge cases.")
def _(p):
    img, d = base("1 · FROM A DIAGRAM TO A STATE GRAPH", "A node is a moment, labelled by the last message", "session_diagram and Faithful.typestates of Images")
    paste_fit(img, os.path.join(WORK, "seq_Images.png"), (80, 240, 760, 760))
    paste_fit(img, graph_png("Images"), (800, 240, 1840, 560), frame=False)
    box(d, 800, 600, 500, 300, GREEN, "atoms", "after(m): m was the message just delivered.  terminal: the conversation may stop here.", 26)
    box(d, 1340, 600, 500, 300, BLUE, "stutter", "An ended session repeats, keeping its last message: every path is infinite.", 26)
    wrap(d, 80, 800, "data/field_atom.json: " + FIELD["terminalConvention"], F(R, 21), 680, MUTED, 6)
    img.save(p)

TABLE = [("on(GetImage)", "on delivery of GetImage"), ("stop", "the conversation may stop here"),
         ("EX φ", "SOME next step leads to a moment where φ"), ("AX φ", "EVERY next step leads to a moment where φ"),
         ("AG φ", "φ at every moment that can ever be reached"), ("φ → ψ", "whenever φ, also ψ")]
@scene("reading", "Six pieces of C T L carry the whole translation. After, and terminal, the atoms. E X: some next step leads somewhere "
       "phi holds. A X: every next step does. A G: at every reachable moment. And implies: whenever this, also that. "
       "Read E as there is a future, and A as in every future.")
def _(p):
    img, d = base("2 · SIX PIECES OF CTL", "E: some future.  A: every future.", "the book's table, chapter Faithful CTL")
    for i, (a, b) in enumerate(TABLE):
        y = 260 + i * 110
        d.rounded_rectangle([80, y, 1840, y + 92], radius=12, fill=CARD, outline=EDGE, width=2)
        d.text((120, y + 24), a, font=F(M, 36), fill=AMBER); d.text((620, y + 28), b, font=F(R, 32), fill=TEXT)
    img.save(p)

r_img = {x["name"]: x for x in RULES["Images"]["rules"]}
@scene("moment", "Stand just after GetImage. Three things are true. An image can come next, and then it may stop. A not found can come next, "
       "and then it may stop. And whatever comes next is one of those two. The two E X lines rule out a server that can never say not found. "
       "The A X line rules out a server that says anything else. Wrap it in A G, at every moment where the last message was GetImage, "
       "and it is a rule about the whole conversation. This is the rule LeanFM writes.")
def _(p):
    img, d = base("3 · ONE MOMENT, THREE LINES", "Possible: EX.  Nothing else: AX.  Always: AG.", "session_ctl faithful rules · data/rules_Images.json")
    rows = [("EX (Image ∧ stop)", "an Image can come next, and then it may stop", GREEN),
            ("EX (NotFound ∧ stop)", "a NotFound can come next, and then it may stop", GREEN),
            ("AX ((Image ∧ stop) ∨ (NotFound ∧ stop))", "whatever comes next is one of those", BLUE)]
    for i, (f, t, c) in enumerate(rows):
        y = 260 + i * 120
        d.rounded_rectangle([80, y, 1840, y + 100], radius=12, fill=CARD, outline=c, width=2)
        d.text((110, y + 16), f, font=F(M, 32), fill=c); d.text((110, y + 60), t, font=F(R, 26), fill=TEXT)
    rule = r_img["typestate 1: GetImage"]
    box(d, 80, 650, 1760, 330, AMBER, "typestate 1: GetImage, as LeanFM writes it", rule["notation"], 30, mono=True)
    img.save(p)

up = TS["Upload"]
@scene("refine", "Naming a moment by its last message is not always enough. Here an upload is acknowledged twice: after Begin and after Commit. "
       "Both moments have the same last message, Ack. So LeanFM refines. Round zero groups nodes by label and ending, and the two Acks share a colour. "
       "Round one splits a group when its members step into different groups: one Ack is followed by Commit, the other by Done. "
       "Nothing changes in round two, so it stops. These classes are the typestates, and the number of rounds needed is the lookahead: here, one.",
       animated=True)
def refine(n):
    g0 = Image.open(graph_png("Upload", 0, "upload_r0")).convert("RGB")
    g1 = Image.open(graph_png("Upload", 1, "upload_r1")).convert("RGB")
    p0, p1 = os.path.join(WORK, "upload_r0.png"), os.path.join(WORK, "upload_r1.png")
    labels = [n["message"] or "start" for n in up["nodes"]]
    for f in range(n):
        t = f / max(1, n - 1); rnd = 0 if t < 0.5 else 1
        img, d = base("4 · WHEN THE LAST MESSAGE IS NOT ENOUGH", f"Refinement, round {rnd}", "Faithful.typestates of Upload · data/typestates.json")
        paste_fit(img, os.path.join(ROOT, p0 if rnd == 0 else p1), (80, 240, 1840, 470), frame=False)
        classes = up["rounds"][rnd]
        groups = {}
        for i, c in enumerate(classes): groups.setdefault(c, []).append(i)
        for k, (c, members) in enumerate(sorted(groups.items())):
            x = 80 + (k % 3) * 590; y = 520 + (k // 3) * 110
            col = tuple(int(CLASS[c % len(CLASS)][j:j + 2], 16) for j in (1, 3, 5))
            d.rounded_rectangle([x, y, x + 560, y + 90], radius=12, fill=CARD, outline=col, width=4)
            d.text((x + 20, y + 12), f"class {c}", font=F(B, 26), fill=col)
            d.text((x + 20, y + 50), ", ".join(f"n{i} {labels[i]}" for i in members), font=F(M, 24), fill=TEXT)
        msg = ("round 0: same last message and ending, same class: the two Acks are together" if rnd == 0 else
               f"round 1: an Ack followed by Commit, an Ack followed by Done: split.  lookahead {up['lookahead']}, {up['typestates']} typestates")
        d.text((80, 790), msg, font=F(B, 30), fill=AMBER if rnd == 0 else GREEN)
        wrap(d, 80, 860, "Each round splits a class by the classes its successors reach: one pass over the steps per round, lookahead + 1 rounds. "
             "The result is bisimilarity: two nodes share a typestate exactly when no observer can tell them apart.", F(R, 26), 1760, TEXT)
        yield img

r_up = {x["name"]: x for x in RULES["Upload"]["rules"]}
def antecedent(notation):
    s = notation[len("AG ("):]; depth = 0
    for i, ch in enumerate(s):
        depth += ch == "("; depth -= ch == ")"
        if depth == 0 and s[i:i + 3] == " → ": return s[:i]
    return s
@scene("names", "So a typestate's name says what it needs to. The first Ack is named: the last message was Ack, it may not stop, and next comes Commit. "
       "The second: Ack, and next comes Done. These names exclude each other: no state of any system can satisfy both. "
       "LeanFM writes them as s-expressions with shared parts. Hash zero, defined once, used again, so a name that looks k steps ahead "
       "does not blow up in size.")
def _(p):
    img, d = base("5 · NAMING A TYPESTATE", "A name looks as far ahead as it must", "session_ctl faithful rules · data/rules_Upload.json")
    a2, a4 = r_up["typestate 2: Ack"], r_up["typestate 4: Ack"]
    box(d, 80, 250, 1760, 170, BLUE, "typestate 2: the Ack after Begin", antecedent(a2["notation"]), 28, mono=True)
    box(d, 80, 450, 1760, 170, GREEN, "typestate 4: the Ack after Commit", antecedent(a4["notation"]), 28, mono=True)
    sx = a2["formula"]
    code(d, 80, 650, 1760, 330, "typestate 2's rule as LeanFM sends it (shared parts #n= … #n#)",
         chunks(sx, 92), 24, AMBER)
    img.save(p)

r_po = RULES["PlaceOrder"]
@scene("rules", "Do that for every typestate, add one rule for the start, and you have the faithful rules. PlaceOrder has ten typestates "
       "and eleven rules. The theorem: a system satisfies all eleven exactly when it is bisimilar to the protocol. And bisimilar systems "
       "satisfy the same C T L. So no set of C T L formulas pins the protocol down more tightly. Every other property, like every request "
       "is answered, is a consequence of these eleven.")
def _(p):
    img, d = base("6 · THE FAITHFUL RULES", f"{r_po['typestates']} typestates, {r_po['ruleCount']} rules, lookahead {r_po['lookahead']}", "session_ctl faithful rules · data/rules_PlaceOrder.json")
    paste_fit(img, graph_png("PlaceOrder", rankdir="TB", path="place_tb"), (80, 240, 620, 1000), frame=False)
    y = 250
    for x in r_po["rules"]:
        nm = x["name"]; f = x["notation"]
        d.text((660, y), nm, font=F(B, 21), fill=GREEN)
        f2 = f if len(f) <= 88 else f[:87] + "…"
        d.text((660, y + 28), f2, font=F(M, 19), fill=TEXT); y += 62
    d.rounded_rectangle([660, 942, 1840, 1030], radius=12, fill=CARD, outline=AMBER, width=3)
    d.text((684, 958), "M ⊨ rules  ⇔  M bisimilar to the protocol", font=F(B, 30), fill=AMBER)
    d.text((684, 996), "so nothing written in CTL can tell more systems apart", font=F(R, 22), fill=TEXT)
    img.save(p)

ca = CMP["answer"]; T_ = TIM
@scene("decide", "Checking eleven formulas one at a time would cost the number of typestates times the model. LeanFM never does that. "
       "Because a message carrying its prev makes the typestates deterministic, it decides faithfulness in one walk, pairing each node of "
       "a candidate with the one typestate it must be. Swap sold out for a backorder, and the walk stops after CreateOrder, naming what each side allows. "
       "GoServer's sixteen hundred rules are written in under a second.")
def _(p):
    img, d = base("7 · DECIDED IN ONE WALK", "Faithful or not, with the place they differ", "session_ctl faithful lean · data/faithful_compare.json · data/timings.json")
    box(d, 80, 250, 1760, 120, RED, f"{ca['verdict']} · method {ca['method']} · {1000 * CMP['seconds']:.1f} ms", f"candidate: {CMP['variant']}", 28)
    box(d, 80, 400, 860, 260, GREEN, "protocol allows, after " + " → ".join(ca["path"]), ", ".join(ca["protocolNext"]), 34)
    box(d, 980, 400, 860, 260, RED, "candidate allows, after " + " → ".join(ca["path"]), ", ".join(ca["candidateNext"]), 34)
    box(d, 80, 690, 1760, 300, AMBER, "cost", f"GoServer: {T_['goserver_rules']} faithful rules written in {T_['goserver_rules_s']:.2f} s on this machine. "
        "Deciding them one formula at a time took 36 s (selfhost.session.faithful); the walk is linear in the steps.", 28)
    img.save(p)

@scene("values", "Now the data. Look at what the state graph holds: labels. Not one value. Ask C T L whether every payment's amount is ten, "
       "and the answer is unknown: field values are not in the model. That is not a bug, it is the split. The shape, which messages can follow which, "
       "is decided once, by a model checker, for every run. The values are checked by where clauses, run over the data each logged message carries.")
def _(p):
    img, d = base("8 · THE GRAPH HOLDS LABELS, NOT VALUES", "Two layers: the shape and the values", "session_ctl with a field atom · data/field_atom.json")
    box(d, 80, 250, 1760, 170, AMBER, f"{FIELD['notation']}   →   {FIELD['verdict']}", FIELD["unobservableAtoms"][0], 28)
    box(d, 80, 460, 860, 500, GREEN, "the shape: CTL", "State graph of labels and endings. Typestates, faithful rules, any formula: decided for every run at once, by session_ctl.", 30)
    box(d, 980, 460, 860, 500, BLUE, "the values: where", "Expressions over message ids and their fields, interpreted (never executed) by session_conform over each logged event: true, false, or unchecked with the reason.", 30)
    img.save(p)

pc = {x["name"]: x["answer"] for x in PCON}
@scene("guards", "A where clause on a branch's first message is a guard: it selects the branch by data. Here a big order gets a discount, a small one a quote. "
       "To the model checker both branches are possible: E F discount, proved. E F quote, proved. And once a discount, never a quote, proved. "
       "The guard bites on the log. A hundred and fifty with a discount conforms. Fifty with a discount violates, and the answer names the condition "
       "and the value it read. And if the total was never logged, it does not pass silently: it is unchecked, with the reason.")
def _(p):
    img, d = base("9 · A GUARD PICKS A BRANCH", "Both branches in the shape; the data picks one", "session_ctl and session_conform · data/pricing_ctl.json · data/pricing_conform.json")
    lines = [l for l in proto("Pricing").splitlines() if l.strip()][4:]
    code(d, 80, 240, 860, 400, "Pricing (protocols/Pricing.leanfm)", lines, 21, mark=("where",))
    for i, x in enumerate(PCTL):
        y = 250 + i * 128; v = x["answer"]["verdict"]
        d.rounded_rectangle([980, y, 1840, y + 112], radius=12, fill=CARD, outline=verdict_color(v), width=2)
        d.text((1004, y + 12), x["answer"].get("notation", x["formula"])[:52], font=F(M, 24), fill=TEXT)
        d.text((1004, y + 60), f"session_ctl: {v}", font=F(B, 26), fill=verdict_color(v))
    for i, nm in enumerate(["total 150, Discount", "total 50, Discount", "total not logged"]):
        a = pc[nm]; y = 670 + i * 120; v = a["verdict"]; unchecked = bool(a["unchecked"])
        col = AMBER if unchecked else verdict_color(v)
        d.rounded_rectangle([80, y, 1840, y + 104], radius=12, fill=CARD, outline=col, width=2)
        d.text((104, y + 12), f"{nm}:  {v}" + ("  (1 unchecked)" if unchecked else ""), font=F(B, 26), fill=col)
        detail = a["unchecked"][0] if unchecked else (a["issues"][0] if a.get("issues") else a["reading"])
        d.text((104, y + 58), event_part(detail), font=F(M, 20), fill=TEXT)
    img.save(p)

gc = {x["name"]: x["answer"] for x in PCON}
@scene("gap", "Here is where the two layers can disagree. Change the quote's guard to under fifty, and leave a gap. The shape still proves "
       "A F terminal: every conversation ends. But an order of seventy fails both guards. A quote violates, a discount violates, and the conversation "
       "is stuck where the shape promised a step. So: a safety property proved on the shape, A G of something, holds on every run that conforms. "
       "A promise that something will happen, A F, or that it can, E F, only holds if the guards of each choice cover every value.")
def _(p):
    img, d = base("10 · WHEN DATA BLOCKS THE SHAPE", "Guards of a choice must cover every value", "protocols/PricingGap.leanfm · data/pricing_gap_ctl.json · data/pricing_conform.json")
    box(d, 80, 250, 1760, 130, GREEN, f"shape: {GAP.get('notation', 'AF stop')}  →  {GAP['verdict']}", GAP["reading"], 28)
    for i, nm in enumerate(["gap: total 70, Quote", "gap: total 70, Discount"]):
        a = gc[nm]; y = 410 + i * 140
        d.rounded_rectangle([80, y, 1840, y + 120], radius=12, fill=CARD, outline=RED, width=2)
        d.text((104, y + 14), f"values: {nm[5:]}  →  {a['verdict']}", font=F(B, 28), fill=RED)
        d.text((104, y + 66), event_part(a["issues"][0]), font=F(M, 21), fill=TEXT)
    box(d, 80, 710, 860, 290, GREEN, "carries over", "AG safety proved on the shape holds on every conforming run: guards only remove runs.", 30)
    box(d, 980, 710, 860, 290, AMBER, "needs covering guards", "AF (it will happen) and EF (it can happen) hold on the data only if each choice's guards cover every value.", 30)
    img.save(p)

pl = {x["name"]: x["answer"] for x in PLACE}
@scene("across", "A condition can relate two messages. In PlaceOrder the payment must match the quote: p dot amount equals q dot price, "
       "naming the earlier message by its id. Pay ten against a price of ten and the run conforms. Pay twelve, and it stops at the payment, "
       "with both values in the answer. A structure can carry constraints of its own, on every message of its type: an image's content length "
       "must equal the bytes actually sent, and a log that says otherwise is caught.")
def _(p):
    img, d = base("11 · CONDITIONS ACROSS MESSAGES", "Ids in scope, fields compared, values reported", "session_conform · data/place_conform.json · data/images_conform.json")
    lines = [l for l in proto("PlaceOrder").splitlines() if "q: Quote" in l or "p: Pay" in l or "c: Charge" in l]
    code(d, 80, 240, 1760, 200, "PlaceOrder (examples/sessions/PlaceOrder.leanfm)", [l.strip() for l in lines], 24, mark=("where",))
    for i, nm in enumerate(["amount 10, price 10", "amount 12, price 10"]):
        a = pl[nm]; y = 470 + i * 120; v = a["verdict"]
        d.rounded_rectangle([80, y, 1840, y + 104], radius=12, fill=CARD, outline=verdict_color(v), width=2)
        d.text((104, y + 12), f"{nm}:  {v}", font=F(B, 26), fill=verdict_color(v))
        d.text((104, y + 58), event_part(a["issues"][0]) if a.get("issues") else a["reading"], font=F(M, 20), fill=TEXT)
    st = [l for l in proto("Images").splitlines() if "size" in l or "contentLength" in l]
    code(d, 80, 730, 700, 270, "structure Image", [l.strip() for l in st], 22, AMBER, mark=("measured",))
    ia = IMG["answer"]
    box(d, 820, 730, 1020, 270, RED, f"{IMG['name']}: {ia['verdict']}", ia["issues"][0].split(": ", 1)[1], 22, mono=True)
    img.save(p)

fa = FLAT["answer"]; SESS = [GREEN, BLUE, AMBER, VIOLET]
@scene("identity", "Some equations are not conditions at all: they say which messages belong together. Created mints an order id, Fresh. "
       "GetOrder carries it, Link. That equation is a where clause too, and it is how LeanFM untangles a flat log: twelve events, three orders "
       "interleaved, no session ids. GetOrder names no cause; its order id places it. Each thread is then one run of the shape, "
       "and the faithful rules and the where clauses apply to it alone.")
def _(p):
    img, d = base("12 · EQUATIONS THAT ARE IDENTITY", "Fresh and Link: which messages belong together", "session_conform of a flat log · data/orders_flat.json")
    sess = {}
    for si, s in enumerate(fa["derivedSessions"]["sessions"]):
        for i in s["events"]: sess[i] = si
    for i, e in enumerate(FLAT["events"]):
        c = SESS[sess.get(i, 0) % 4]; y = 240 + i * 62
        d.rounded_rectangle([80, y, 1150, y + 52], radius=8, fill=CARD, outline=c, width=2); d.rectangle([80, y + 4, 88, y + 48], fill=c)
        d.text((104, y + 12), f"{i + 1:>2}  {e['label']}", font=F(B, 22), fill=c)
        fs = " ".join(f"{k}={v}" for part in ("headers", "path") for k, v in (e.get(part) or {}).items())
        d.text((440, y + 14), (f"cause {e['cause']}   " if e.get("cause") else "no cause   ") + fs, font=F(M, 20), fill=TEXT)
    for si, s in enumerate(fa["derivedSessions"]["sessions"]):
        d.text((1200, 250 + si * 50), f"{s['key']}: {s['count']} events", font=F(B, 28), fill=SESS[si])
    box(d, 1200, 420, 640, 330, BLUE, "identity, not a condition", "Created's orderId is Fresh; GetOrder's is Link: equal values, one session. A condition like amount = 10 is never read as identity.", 25)
    wrap(d, 1200, 780, f"{fa['verdict']}: {fa['reading'].split(': ', 1)[1]}", F(B, 26), 640, GREEN)
    img.save(p)

@scene("together", "Put together, a run conforms when three things hold. Its equations place each event in one session. Its sequence of labels "
       "is a path of the shape, which the faithful rules pin down exactly. And every where clause on that path is true, or is reported unchecked "
       "with the reason, never silently passed. The model checker proves the shape once, for every run. The where clauses are checked per run, "
       "in time linear in the log. Proposed next: quantified formulas, for every order id, so C T L can speak about values too.")
def _(p):
    img, d = base("13 · WHAT A RUN MUST SATISFY", "Identity, then shape, then values")
    rows = [("1 identity", BLUE, "equations (cause, Fresh/Link, sessions by) place every event in exactly one session; two candidates is reported"),
            ("2 shape", GREEN, "the session's labels are a path of the state graph: the faithful rules, decided once by session_ctl"),
            ("3 values", AMBER, "every where clause and structure constraint on that path is true, or unchecked with its reason")]
    for i, (k, c, t) in enumerate(rows):
        y = 260 + i * 160
        d.rounded_rectangle([80, y, 1840, y + 136], radius=14, fill=CARD, outline=c, width=3)
        d.text((110, y + 20), k, font=F(B, 36), fill=c); wrap(d, 460, y + 26, t, F(R, 30), 1350, TEXT)
    d.text((80, 780), "carries over: AG safety proved on the shape.   needs covering guards: AF and EF.", font=F(B, 30), fill=PINK)
    d.text((80, 850), "proposed: selfhost.session.identity.quantified (forall orderId: …), selfhost.session.correlation", font=F(M, 26), fill=MUTED)
    img.save(p)

OUTRO = "The diagram is the shape, exactly, in C T L. The where clauses are the data. Check each where it is cheap, and know what carries over."
@scene("outro", OUTRO)
def _(p):
    img, d = base("LEANFM · CTL AND WHERE CLAUSES")
    d.text((80, 320), "The shape, exactly.", font=F(B, 92), fill=TEXT)
    d.text((80, 440), "The data, checked where it lives.", font=F(B, 64), fill=AMBER)
    d.text((80, 600), "book: Faithful CTL · selfhost.session.faithful · selfhost.session.where · selfhost.session.wire-constraints", font=F(M, 26), fill=MUTED)
    img.save(p)

# ── narration, pictures, music bed ──
def tts(text, path):
    run([PIPER, "--model", VOICE, "--output_file", path], input=text.encode(), stderr=subprocess.DEVNULL)
    with wave.open(path) as w: return w.getnframes() / w.getframerate()

LEAD, TAIL, MUSIC_TAIL = 0.8, 1.4, 10.0
only = os.environ.get("ONLY")
parts, voice_at, t = [], [], 0.0
for id, text, fn, animated in scenes:
    if only:
        if id == only:
            if animated:
                imgs = list(fn(60)); imgs[10].save(os.path.join(WORK, f"{id}_a.png")); imgs[50].save(os.path.join(WORK, f"{id}_b.png"))
            else: fn(os.path.join(WORK, f"{id}.png"))
        continue
    wav = os.path.join(WORK, f"{id}.wav"); mp4 = os.path.join(WORK, f"{id}.mp4")
    secs = LEAD + tts(text, wav) + TAIL + (MUSIC_TAIL if id == "outro" else 0)
    fade = f"fade=t=in:st=0:d=0.4,fade=t=out:st={secs - 0.4:.3f}:d=0.4,format=yuv420p"
    if animated:
        n = int(secs * FPS)
        enc = subprocess.Popen(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-vf", fade, "-c:v", "libx264", "-preset", "medium",
                                "-crf", "18", mp4], stdin=subprocess.PIPE)
        for img in fn(n): enc.stdin.write(img.tobytes())
        enc.stdin.close()
        if enc.wait() != 0: sys.exit("encode failed")
    else:
        png = os.path.join(WORK, f"{id}.png"); fn(png)
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-t", f"{secs:.3f}",
             "-i", png, "-vf", fade if parts else fade.replace("fade=t=in:st=0:d=0.4,", ""), "-c:v", "libx264", "-preset", "medium", "-crf", "18", mp4])
    voice_at.append((wav, t + LEAD)); parts.append(mp4); t += secs
    print(f"{id}: {secs:.1f}s")
if only: sys.exit(0)
total = t

# the score, its sympathetic strings at 0.9995 (the source file is unchanged)
SYM_FROM, SYM_TO = "sym mic decay 0.9999", "sym mic decay 0.9995"
mq = open(os.path.join(SCORE_DIR, SCORE)).read()
assert SYM_FROM in mq
score_mq = os.path.join(WORK, "score.mq"); open(score_mq, "w").write(mq.replace(SYM_FROM, SYM_TO))
cycles = int(total / 27.5) + 1
score = os.path.join(WORK, "score.wav")
run([f"{SCORE_DIR}/zig-out/bin/maqam-live", "--render", score_mq, "--cycles", str(cycles), "--rate", "48000", "--wav", score], cwd=SCORE_DIR)

video = os.path.join(WORK, "video.mp4")
with open(os.path.join(WORK, "parts.txt"), "w") as f:
    for p in parts: f.write(f"file '{p}'\n")
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(WORK, "parts.txt"), "-c", "copy", video])
inputs = ["-i", video, "-i", score]; voices = []
for k, (wav, at) in enumerate(voice_at):
    inputs += ["-i", wav]; ms = int(at * 1000)
    voices.append(f"[{k + 2}:a]adelay={ms}|{ms},aformat=sample_rates=48000:channel_layouts=stereo[v{k}]")
mix = ";".join(voices) + ";" + "".join(f"[v{k}]" for k in range(len(voices))) + \
      f"amix=inputs={len(voices)}:normalize=0,volume=1.6,apad,atrim=0:{total:.3f},asplit=2[voice][key];" \
      f"[1:a]aformat=sample_rates=48000:channel_layouts=stereo,atrim=0:{total:.3f},loudnorm=I=-20:TP=-2:LRA=11," \
      f"afade=t=in:st=0:d=2,afade=t=out:st={total - 6:.3f}:d=6[music];" \
      f"[music][key]sidechaincompress=threshold=0.03:ratio=8:attack=20:release=600:makeup=1[bed];" \
      f"[bed][voice]amix=inputs=2:normalize=0,alimiter=limit=0.95[a]"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *inputs, "-filter_complex", mix, "-map", "0:v", "-map", "[a]",
     "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", "-t", f"{total:.3f}", OUT])
print(f"wrote {OUT} ({total:.1f}s)")
