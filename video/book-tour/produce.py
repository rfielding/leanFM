"""A tour of the book Requirements Logic, by doing it: a real clone of LeanFM, Claude Desktop connected
over MCP (the chat is re-enacted; every tool answer in it is real), TicTacToe from a prompt to its
diagrams and proofs, the one function CTL is made of, faithful rules, and the guinea pig cage with
claims over measurements. Every terminal line was printed by the command shown (capture.py), and every
diagram, verdict, margin and chart is a LeanFM answer (fetch.py). Narration: local Piper voice.
Usage: produce.py [out.mp4]   (ONLY=<scene> renders one scene's picture)"""
import json, os, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data")
WORK = os.path.join(D, "build"); os.makedirs(WORK, exist_ok=True)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "requirements-logic-tour.mp4")
PIPER = f"{ROOT}/video/.conda/bin/piper"
VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
FPS, W, H = 30, 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85); HEAD = (32, 40, 54)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184)
RED = (248, 113, 113); BLUE = (125, 175, 255); NAVY = (30, 58, 94); GOLD = (226, 185, 75)
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_fonts = {}
def F(p, s):
    if (p, s) not in _fonts: _fonts[p, s] = ImageFont.truetype(p, s)
    return _fonts[p, s]
def run(cmd, **kw): subprocess.run(cmd, check=True, **kw)
def load(name): return json.load(open(os.path.join(DATA, f"{name}.json")))

TERM = load("terminal"); MCP = load("mcp"); TD = load("ttt_draft"); TE = load("ttt_ends"); TF = load("ttt_fixed")
IMG = load("images"); CAGE = load("cage"); ROLES = load("ttt_roles")

def svg_png(svg, name, width=1400):
    p = os.path.join(WORK, name + ".svg"); open(p, "w").write(svg); png = os.path.join(WORK, name + ".png")
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-width", str(width), "-i", p, png]); return png
def pdf_png(path, name, dpi=150):
    out = os.path.join(WORK, name); run(["pdftoppm", "-r", str(dpi), "-png", "-singlefile", path, out]); return out + ".png"

PNG = {"ttt_draft": svg_png(TD["svg"], "d_ttt_draft"), "ttt_fixed": svg_png(TF["svg"], "d_ttt_fixed"),
       "images": svg_png(IMG["svg"], "d_images", 900),
       "images_ts": pdf_png(f"{ROOT}/book/generated/ctl-images-ts-dark.pdf", "images_ts"),
       "cover": pdf_png(f"{ROOT}/book/figures/cover-cage.pdf", "cover", 200)}
for k, c in enumerate(CAGE["claims"]): PNG[f"sig{k}"] = svg_png(c["svg"], f"sig{k}", 920)

DEEP = load("deep"); LIVE = load("live")
for n in ("placeorder", "construct-loop", "construct-bounded-loop", "construct-parallel", "include", "race", "blind"):
    PNG["d_" + n] = svg_png(DEEP[n]["svg"], "d_" + n.replace("construct-", ""), 1300)
for n in ("placeorder", "retry", "parallel"):
    PNG[n + "_ts"] = pdf_png(f"{ROOT}/book/generated/ctl-{n}-ts-dark.pdf", n + "_ts")

MORE = load("more")
import re, textwrap
def tex_listing(t):
    """The text of a generated lstlisting, as LeanFM wrote it."""
    t = re.sub(r"\\begin\{lstlisting\}\[[^\]]*\]\n?", "", t)
    return t.replace("\\end{lstlisting}", "").strip()
def tex_rows(t):
    """The cells of a generated tabular, with the LaTeX taken off."""
    rows = []
    for line in t.splitlines():
        if "&" not in line: continue
        line = re.sub(r"\\texttt\{([^}]*)\}", r"\1", line).replace("\\\\", "").replace("\\,", " ").replace("\\", "")
        rows.append([c.strip() for c in line.split("&")])
    return rows
def wrapped(lines, n=110):
    out = []
    for l in lines: out += textwrap.wrap(l, n, subsequent_indent="    ") or [""]
    return out

# ── drawing ──
def base(tag, title=None, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN)
    d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    if title: d.text((80, 112), title, font=F(B, 50), fill=TEXT)
    if sub: d.text((80, 182), sub, font=F(R, 28), fill=AMBER)
    return img, d

KW = {"protocol", "from", "to", "cause", "choice", "or", "loop", "continue", "at", "most", "otherwise", "parallel", "and",
      "always", "never", "possibly", "inevitably", "within", "throughout", "above", "below", "implies", "on", "def", "partial", "fun"}
def code(d, x, y, w, h, head, lines, size=22, color=GREEN, mark=()):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=EDGE, width=2)
    d.rounded_rectangle([x, y, x + w, y + 52], radius=14, fill=HEAD); d.rectangle([x, y + 38, x + w, y + 52], fill=HEAD)
    d.text((x + 22, y + 12), head, font=F(B, 24), fill=color)
    f = F(M, size); lh = int(size * 1.4); yy = y + 68
    for line in lines:
        if yy + lh > y + h: break
        if any(m in line for m in mark): d.rectangle([x + 4, yy - 3, x + w - 4, yy + lh - 5], fill=(22, 58, 46))
        cx, tok = x + 22, ""
        for ch in line + " ":
            if ch.isalnum() or ch == "_": tok += ch; continue
            if tok:
                d.text((cx, yy), tok, font=f, fill=BLUE if tok in KW else TEXT); cx += f.getlength(tok); tok = ""
            d.text((cx, yy), ch, font=f, fill=AMBER if ch in "()" else TEXT); cx += f.getlength(ch)
        yy += lh

def paste_fit(img, path, box, frame=True):
    src = Image.open(path).convert("RGBA")
    im = Image.new("RGB", src.size, BG); im.paste(src, (0, 0), src)
    bw, bh = box[2] - box[0], box[3] - box[1]
    s = min(bw / im.width, bh / im.height, 2.0)
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

def verdict_color(v): return GREEN if v in ("proved", "conforms", "holds", "ok") else RED if v in ("disproved", "violates", "fails") else AMBER

# ── the terminal: each step's command typed, then what it printed ──
def terminal(steps, n, title="bash"):
    """n frames of a terminal running `steps` (from capture.py) one after another."""
    f = F(M, 24); lh = 34; top, left = 150, 110; rows = (H - top - 90) // lh
    typing = [min(len(s["cmd"]), 70) for s in steps]
    need = sum(t + 8 for t in typing)
    pause = max(6, (n - need) // max(1, len(steps)))
    timeline = []
    for s, t in zip(steps, typing):
        timeline.append((s, t, t + 8 + pause))
    def frame(i):
        img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
        d.rounded_rectangle([80, 90, W - 80, H - 50], radius=16, fill=(10, 12, 16), outline=EDGE, width=2)
        d.rounded_rectangle([80, 90, W - 80, 136], radius=16, fill=HEAD); d.rectangle([80, 122, W - 80, 136], fill=HEAD)
        for k, c in enumerate([(248, 113, 113), (251, 191, 36), (52, 211, 153)]): d.ellipse([102 + k * 30, 104, 120 + k * 30, 122], fill=c)
        d.text((W // 2, 102), title, font=F(R, 22), fill=MUTED, anchor="mt")
        lines, t = [], i
        for s, ty, dur in timeline:
            prompt = s["cwd"] + " $ "
            if t < 0: break
            shown = s["cmd"] if t >= ty else s["cmd"][:int(len(s["cmd"]) * t / max(1, ty))]
            lines.append([(prompt, GREEN), (shown + ("█" if t < ty + 4 else ""), TEXT)])
            if t >= ty + 4:
                for o in s["out"]: lines.append([(o[:120], MUTED if s["status"] == 0 else RED)])
            t -= dur
        for k, parts in enumerate(lines[-rows:]):
            x = left
            for txt, col in parts: d.text((x, top + k * lh), txt, font=f, fill=col); x += f.getlength(txt)
        return img
    for i in range(n): yield frame(i)

# ── the chat, re-enacted: a person's message, Claude's reply, the LeanFM tool calls and their real answers ──
def chat(p, turns, note="re-enacted chat; every tool answer is LeanFM's real one"):
    img = Image.new("RGB", (W, H), (26, 25, 24)); d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 300, H], fill=(20, 19, 18))
    d.text((40, 40), "Claude Desktop", font=F(B, 28), fill=TEXT)
    d.text((40, 84), "leanfm · connected", font=F(R, 20), fill=GREEN)
    d.text((40, H - 60), note, font=F(R, 16), fill=MUTED)
    y = 50; x0, x1 = 380, W - 120
    for who, body in turns:
        if who == "user":
            f = F(R, 28); w = min(x1 - x0, int(d.textlength(body, font=f)) + 60)
            d.rounded_rectangle([x1 - w, y, x1, y + 66], radius=20, fill=(48, 46, 43)); d.text((x1 - w + 30, y + 17), body, font=f, fill=TEXT); y += 96
        elif who == "claude":
            y = wrap(d, x0, y, body, F(R, 27), x1 - x0, TEXT, 10) + 22
        elif who == "tool":
            name, verdict, detail = body
            d.rounded_rectangle([x0, y, x0 + 900, y + 56], radius=12, fill=(36, 35, 33), outline=EDGE, width=2)
            d.text((x0 + 22, y + 13), f"leanfm · {name}", font=F(M, 24), fill=BLUE)
            d.text((x0 + 880, y + 13), verdict, font=F(B, 24), fill=verdict_color(verdict), anchor="ra"); y += 70
            if detail: y = wrap(d, x0 + 22, y, detail, F(M, 22), x1 - x0 - 44, MUTED, 6) + 18
        elif who == "code":
            lines = body.splitlines(); h = 30 * len(lines) + 30
            d.rounded_rectangle([x0, y, x1, y + h], radius=12, fill=(17, 17, 16), outline=EDGE)
            for k, l in enumerate(lines): d.text((x0 + 24, y + 16 + 30 * k), l, font=F(M, 22), fill=TEXT)
            y += h + 22
        elif who == "image":
            path, hh = body; paste_fit(img, path, (x0, y, x1, y + hh)); y += hh + 20
    img.save(p)

# ── scenes ──
scenes = []
def scene(id, text, animated=False):
    def deco(fn): scenes.append((id, text, fn, animated)); return fn
    return deco
step = {s["cmd"].split()[0] + str(k): s for k, s in enumerate(TERM)}
T = TERM

@scene("title", "Requirements Logic. A tour of the book, by doing it. We will get LeanFM, connect Claude to it, design a game "
       "from one prompt, check a guinea pig cage while its owners are away, and look at the one function underneath it all.")
def _(p):
    img = Image.new("RGB", (W, H), NAVY); d = ImageDraw.Draw(img)
    d.text((110, 70), "Requirements Logic", font=F(B, 76), fill=GOLD)
    d.text((110, 170), "A Temporal Lean: protocols, claims about what may and must happen next, and the LeanFM server that checks both", font=F(R, 28), fill=GOLD)
    paste_fit(img, PNG["cover"], (110, 240, W - 110, H - 60), frame=False); img.save(p)

@scene("clone", "Start with a checkout. One shallow clone from GitHub takes nine seconds. The book is in the repository, "
       "and so are the specifications LeanFM holds itself to, in the same language it checks.", True)
def _(n): return terminal(T[0:3], n, "~/code: a fresh checkout")

@scene("connect", "make serve builds and starts the server; the first build takes a few minutes. One command prints the entry that tells "
       "Claude Desktop how to reach it, and with dash dash install writes it into Claude Desktop's settings: a small relay that speaks "
       "MCP over standard input and forwards to the server. "
       "Claude and the server can start in either order. The server is up.", True)
def _(n): return terminal(T[3:5], n, "~/code/leanFM: connect Claude Desktop")

@scene("chat_connect", f"In a Claude Desktop chat, ask for the server. Claude lists its {len(MCP['tools'])} tools. From here on "
       "Claude writes, and LeanFM checks, so nothing Claude writes has to be trusted.")
def _(p):
    names = [t for t in MCP["tools"] if t.startswith(("session_check", "session_ctl", "session_diagram", "session_conform", "check_signal", "session_simulate"))]
    chat(p, [("user", "Find the LeanFM MCP server from this directory."),
             ("tool", ("tools/list", "ok", f"{len(MCP['tools'])} tools from {MCP['server']['name']}: " + ", ".join(names) + ", ...")),
             ("claude", f"Connected. LeanFM offers {len(MCP['tools'])} tools: it checks protocols (session_check), draws them "
                        "(session_diagram), decides claims about them (session_ctl), checks logs against them (session_conform) "
                        "and checks claims over measurements (check_signal).")])


def proto_lines(text):
    """The protocol part of a listing: from its first protocol line on (structures above it are its message types)."""
    lines = text.splitlines()
    k = next((i for i, l in enumerate(lines) if l.startswith("protocol ")), 0)
    return lines[k:]

def code_and_picture(p, tag, title, sub, text, png, size=21, mark=()):
    img, d = base(tag, title, sub)
    code(d, 80, 240, 760, 790, "the protocol", proto_lines(text), size=size, mark=mark)
    paste_fit(img, png, (880, 240, W - 80, 1030)); img.save(p)

@scene("st_intro", "Before the game, the language itself, because the guarantees come from it. A session type is one description of a whole "
       "conversation: who sends what to whom, in what order, and where it branches. It is written once, for everyone, and every role's "
       "part is derived from it. Let us build one up, construct by construct.")
def _(p):
    img, d = base("Part I · the protocol language", "A session type: the whole conversation, written once")
    for k, (t, b) in enumerate([("one global description", "every message, sender, receiver and order, in one place"),
                                ("each role's part is derived", "projection: what this role sends, what it waits for"),
                                ("checked before anything runs", "races, blind choices and borrowed causes are refused"),
                                ("it is also the requirement", "a short list of claims a log or an implementation must satisfy")]):
        y = 260 + k * 190
        d.rounded_rectangle([80, y, W - 80, y + 160], radius=16, fill=CARD, outline=EDGE, width=2)
        d.text((120, y + 30), t, font=F(B, 40), fill=GREEN); d.text((120, y + 95), b, font=F(R, 30), fill=TEXT)
    img.save(p)

@scene("st_images", "The smallest useful protocol. A browser asks a server for an image. The q colon names the request, so the answers can "
       "say which request they answer: cause q. Then a choice: the server sends an Image, or a NotFound. Whoever sends the first message of "
       "every branch decides; here that is the server, and the diagram says so. Requests are solid arrows, replies dotted.")
def _(p): code_and_picture(p, "Chapter 2 · a request with two answers", "Images", "q names the request; cause q ties each answer to it",
                           IMG["lean"], PNG["images"], size=26, mark=("cause q",))

@scene("st_placeorder", "Three roles and nested choices. A client orders; the shop quotes or says it is sold out. After a quote the client pays, "
       "the shop charges the bank, and the bank's choice decides between a receipt and a declined payment. A where clause ties the data "
       "together: the amount paid must equal the price quoted. Each message has a type, declared above it, so the fields are known.")
def _(p): code_and_picture(p, "Chapter 2 · three roles, nested choices, a condition on data", "PlaceOrder",
                           "where p.amount = q.price: a rule about the data, checked on every run", DEEP["placeorder"]["lean"], PNG["d_placeorder"],
                           size=18, mark=("where",))

@scene("st_loops", "Loops come in two kinds. Poll asks until it is done: a loop with a choice, continue to go round again. Retry tries at most "
       "three times: a bounded loop, which the checker unrolls, so it knows exactly how many tries are left, even though no message says so. "
       "Remember that; it comes back when we look at what the guarantee costs.")
def _(p):
    img, d = base("Chapter 2 · loops", "Poll, and Retry at most 3")
    code(d, 80, 230, 860, 330, "Poll", proto_lines(DEEP["construct-loop"]["lean"]), size=19)
    code(d, 980, 230, W - 1060, 330, "Retry", proto_lines(DEEP["construct-bounded-loop"]["lean"]), size=19, mark=("at most",))
    paste_fit(img, PNG["d_construct-loop"], (80, 590, 940, 1040)); paste_fit(img, PNG["d_construct-bounded-loop"], (980, 590, W - 80, 1040))
    img.save(p)

@scene("st_parallel", "Parallel runs branches that interleave freely: two independent request and answer pairs, in any order. And include is a "
       "function call. A protocol written once, such as signing in, is called from another with its roles and data passed in, and LeanFM "
       "checks the call the way a compiler checks one: the right roles, the right fields, the result used correctly.")
def _(p):
    img, d = base("Chapter 2 · parallel, and include as a function call", "Both, and a protocol that includes another")
    code(d, 80, 230, 860, 360, "Both", proto_lines(DEEP["construct-parallel"]["lean"]), size=19)
    paste_fit(img, PNG["d_construct-parallel"], (80, 620, 940, 1040))
    code(d, 980, 230, W - 1060, 810, "include", DEEP["include"]["lean"].splitlines(), size=17, mark=("include",))
    img.save(p)


@scene("st_openapi", "A protocol with routes and statuses is already an HTTP interface. LeanFM writes the OpenAPI document for each role that serves "
       "requests: the paths, the methods, the request and response bodies, one status per answer. It is generated from the same text, so the "
       "API documentation cannot drift from the protocol.")
def _(p):
    img, d = base("Chapter 2 · it is already an HTTP API", "session_openapi: generated, never written by hand")
    code(d, 80, 230, W - 160, 820, "OpenAPI 3.1, from the protocol", tex_listing(MORE["images-openapi"]).splitlines(), size=19)
    img.save(p)

@scene("st_runs", "What does a protocol mean? Its meaning is the set of runs it allows: every order of messages it can produce. session_simulate "
       "produces some. Each event names its session and its thread, the actor that sent it. Three PlaceOrder sessions, interleaved the way a "
       "real server would see them. Every log a real system writes should be one of these runs.", True)
def _(n):
    steps = [{"cwd": "claude", "cmd": "session_simulate  PlaceOrder  instances: 3  seed: 7", "status": 0,
              "out": [f"session {e['session']}   {e['from']:>6} -> {e['to']:<6} {e['label']:<16} thread {e['thread']}" for e in MORE["sim"]["events"][:20]]}]
    return terminal(steps, n, "a protocol is a set of runs")

@scene("ttt_prompt", "Ask for a TicTacToe game. Claude writes it as a protocol: two players and a referee, who sends what to whom, "
       "and in what order. LeanFM checks the text, and notes one thing: " + TD["reading"].split(": ", 2)[-1] +
       ". That is a fair note about any game where the referee speaks to one player first. The bigger question comes next.")
def _(p):
    chat(p, [("user", "Let's design a TicTacToe game with LeanFM."),
             ("claude", "Two players and a referee. X starts a game, the referee tells O it has joined, then the players take turns through the referee until it announces the result:"),
             ("code", "\n".join(TD["lean"].splitlines()[:21])),
             ("tool", ("session_check", TD["verdict"], TD["reading"]))])

@scene("ttt_diagram", "And it draws it. The loop is the rounds. Each choice frame names the role that decides. "
       "Requests are solid lines, replies are dotted, so a reply is never mistaken for the dashed line between two branches.")
def _(p):
    img, d = base("session_diagram · TicTacToe, the first draft", "LeanFM draws what Claude wrote")
    paste_fit(img, PNG["ttt_draft"], (80, 200, W - 80, H - 50)); img.save(p)

@scene("ttt_ends", "Then the question every game must answer: does it always end? LeanFM says no, and shows the run that does not. "
       "The players can trade moves forever. Nothing in the draft says the board fills up.")
def _(p):
    path = [s["message"] for s in TE["evidence"]["path"] if s["message"]]
    loop = TE["evidence"].get("loopsBackTo")
    chat(p, [("user", "Does every game end?"),
             ("tool", ("session_ctl  (inevitably (on Result))", TE["verdict"], TE["reading"])),
             ("code", "counterexample:\n  " + " -> ".join(path) + (f"\n  ... and back to step {loop}, forever" if loop is not None else "")),
             ("claude", "No: the players can trade moves forever. Nothing in the draft says the board fills up.")])

@scene("ttt_fixed", "But it does: nine squares, X first, so X moves at most five times. One phrase says that, and one block says "
       "what happens if a fifth round would go on. Now every requirement Claude wrote down is proved.")
def _(p):
    img, d = base("session_ctl · TicTacToe, fixed", "One phrase: at most 5")
    code(d, 80, 220, 820, 800, "TicTacToe.leanfm", TF["lean"].splitlines(), size=21, mark=("at most", "otherwise"))
    y = 230
    for c in TF["checks"]:
        d.rounded_rectangle([950, y, W - 80, y + 140], radius=14, fill=CARD, outline=verdict_color(c["verdict"]), width=3)
        d.text((975, y + 16), c["says"], font=F(B, 27), fill=TEXT)
        d.text((W - 105, y + 16), c["verdict"], font=F(B, 27), fill=verdict_color(c["verdict"]), anchor="ra")
        wrap(d, 975, y + 62, c["formula"], F(M, 21), W - 1080, MUTED, 4); y += 158
    img.save(p)


def issue_scene(p, tag, title, sub, data, why):
    img, d = base(tag, title, sub)
    code(d, 80, 240, 900, 600, "the protocol", proto_lines(data["lean"]), size=24)
    d.rounded_rectangle([1020, 240, W - 80, 840], radius=16, fill=CARD, outline=RED, width=3)
    d.text((1050, 270), f"session_check: {data['verdict']}", font=F(B, 34), fill=RED)
    y = 340
    for iss in data.get("issues") or [data["reading"]]:
        y = wrap(d, 1050, y, iss if isinstance(iss, str) else json.dumps(iss), F(M, 26), W - 1180, TEXT, 8) + 16
    wrap(d, 80, 880, why, F(R, 30), W - 160, MUTED)
    img.save(p)

@scene("err_intro", "A protocol can be written that no set of independent programs could ever carry out. LeanFM refuses those before anything "
       "runs, and each refusal names the problem. Here are the three that matter most.")
def _(p):
    img, d = base("Chapter 3 · what makes a protocol unplayable", "Three ways to be wrong, each caught before anything runs")
    for k, (t, b) in enumerate([("a race", "two roles each think they decide"), ("a blind choice", "a role must act on a choice it never saw"),
                                ("a borrowed cause", "an answer to a request its sender never received")]):
        x = 80 + k * 600
        d.rounded_rectangle([x, 320, x + 560, 640], radius=16, fill=CARD, outline=RED, width=3)
        d.text((x + 30, 350), t, font=F(B, 40), fill=RED); wrap(d, x + 30, 430, b, F(R, 32), 500, TEXT)
    img.save(p)

@scene("err_race", "A race. The client may cancel, or the shop may ship. But no single role decides: the client starts one branch and the shop "
       "the other, so both can happen at once, and each side believes its own branch was taken. LeanFM names both starters.")
def _(p): issue_scene(p, "Chapter 3 · a race", "Race", "no single role decides the choice", DEEP["race"],
                      "Fix: let one role decide, for example the client asks and the shop answers either way.")

@scene("err_blind", "A blind choice. The shop chooses between capturing the payment and shipping, but the bank's next move depends on which, and "
       "nothing tells the bank. Every role must learn which branch was taken before it acts on it. LeanFM says exactly who cannot tell.")
def _(p): issue_scene(p, "Chapter 3 · a blind choice", "Blind", "a role acts on a choice it never saw", DEEP["blind"],
                      "Fix: send the bank a message in each branch, so it knows which one it is in.")

@scene("err_borrow", "A borrowed cause. The bank answers with cause q, but q went from the shop to the client; the bank never saw it, so it cannot "
       "honestly say what it is answering. A cause is a promise about what the sender received, and LeanFM holds the sender to it.")
def _(p): issue_scene(p, "Chapter 3 · a borrowed cause", "Borrow", "an answer to a request its sender never saw", DEEP["borrow"],
                      "A cause is part of the observable record: logs follow causes to tell which answer goes with which request.")

@scene("ttt_roles", "Each role gets its own view of the game, projected from the whole: what it sends, what it waits for, and nothing else. "
       "These are the typestates LeanFM derives for X and for O. Code generated from them cannot send a message out of turn.")
def _(p):
    img, d = base("Chapter 3 · projection: each role's own view", "The typestates of X and O")
    code(d, 80, 220, W - 160, 410, "X", ROLES["X"].splitlines(), size=19)
    code(d, 80, 645, W - 160, 410, "O", ROLES["O"].splitlines(), size=19)
    img.save(p)


@scene("proj_placeorder", "For PlaceOrder the client's projection is just as concrete: send CreateOrder, then receive a Quote or a SoldOut, and so on, "
       "one state per point in the conversation. LeanFM generates classes from these typestates, one per state, whose methods are exactly what "
       "that state allows. A program built on them cannot send a message out of turn; the type system says no before the code runs.")
def _(p):
    img, d = base("Chapter 3 · projection", "PlaceOrder: the client's and the bank's typestates")
    code(d, 80, 220, W - 160, 400, "Client", DEEP["placeorder"]["roles"].get("Client", "").splitlines(), size=20)
    code(d, 80, 640, W - 160, 400, "Bank", DEEP["placeorder"]["roles"].get("Bank", "").splitlines(), size=20)
    img.save(p)

@scene("err_jam", "One more question: can independent programs, each with its own inbox, really keep the protocol's order? Here B must take X "
       f"and then Y. Give B an inbox of one slot, and C can fill it with Y first: then A cannot deliver X, and B cannot take Y. LeanFM explores every "
       f"state the deployment can reach and finds it: {DEEP['jam']['verdict']}. With an inbox of size zero, a handshake, it is {DEEP['jam0']['verdict']}.")
def _(p):
    img, d = base("Chapter 5 · what a deployment can enforce", "Jam: inbox sizes decide realizability")
    code(d, 80, 240, 700, 300, "the protocol", proto_lines(DEEP["jam"]["lean"]), size=28, mark=("B[1]",))
    for k, (lab, v) in enumerate([("B's inbox: 1 slot", DEEP["jam"]), ("B's inbox: 0 (a handshake)", DEEP["jam0"])]):
        y = 240 + k * 380
        d.rounded_rectangle([820, y, W - 80, y + 340], radius=16, fill=CARD, outline=verdict_color("ok" if v["verdict"] == "realizable" else "fails"), width=3)
        d.text((850, y + 24), lab, font=F(B, 32), fill=TEXT)
        d.text((W - 110, y + 24), v["verdict"], font=F(B, 32), fill=GREEN if v["verdict"] == "realizable" else RED, anchor="ra")
        wrap(d, 850, y + 90, v["reading"], F(M, 22), W - 980, MUTED, 6)
    img.save(p)

@scene("words", "Those requirements are C T L, a logic of the future. Stand at one moment of the conversation: it can go on in several "
       "ways, and each of those in several more. Almost all of C T L is two choices made together. In some future, or in every future. "
       "Eventually, or always. Four everyday words.")
def _(p):
    img, d = base("Chapter 5 · a logic of the future", "Two choices, four words")
    x0, y0, cw, ch = 380, 300, 560, 220
    d.text((x0 + cw // 2, y0 - 50), "p eventually holds", font=F(B, 32), fill=AMBER, anchor="mm")
    d.text((x0 + cw + cw // 2, y0 - 50), "p always holds", font=F(B, 32), fill=AMBER, anchor="mm")
    for r, (row, words) in enumerate([("in some future", ("possibly p", "someAlways p")), ("in every future", ("inevitably p", "always p"))]):
        d.text((x0 - 30, y0 + r * ch + ch // 2), row, font=F(B, 32), fill=AMBER, anchor="rm")
        for c, w in enumerate(words):
            d.rounded_rectangle([x0 + c * cw + 10, y0 + r * ch + 10, x0 + (c + 1) * cw - 10, y0 + (r + 1) * ch - 10], radius=16, fill=CARD, outline=EDGE, width=2)
            d.text((x0 + c * cw + cw // 2, y0 + r * ch + ch // 2), w, font=F(M, 46), fill=GREEN, anchor="mm")
    d.text((W // 2, 820), "never p  =  always (not p)", font=F(M, 36), fill=TEXT, anchor="mm")
    d.text((W // 2, 900), "the only state is the protocol's own: the message just delivered, and whether it may stop", font=F(R, 28), fill=MUTED, anchor="mm")
    img.save(p)

@scene("one_function", "And all four words come from one function. Until: b holds here, or a holds here and the same question is asked of "
       "the next states, reduced with and, for every future, or with or, for some future. Possibly is some-until true. Inevitably is "
       "all-until true. Always and the rest are negations. That one function, under one of two quantifiers, is the whole language.", True)
def _(n): return terminal(T[5:6], n, "book/examples/CtlTiny.lean: the whole core")

@scene("ctltiny", "It is short enough for Lean to check. The book's example compiles, with all its claims holding. Now claim "
       "something false: that b is inevitable from the start, when it is only possible. Lean refuses it, and says which claim and where.", True)
def _(n): return terminal(T[6:8], n, "Lean checks the claims")


@scene("matcher", "Read that table as code and it is a pattern matcher over the event stream, like a regular expression over text. Feed it a log "
       "one message at a time; each row says what may come next, so a message the row does not list is caught the moment it arrives. "
       "That is what session_conform does with a real log.")
def _(p):
    img, d = base("Chapter 5 · the table is a matcher", "follows(log, table)")
    code(d, 80, 240, W - 160, 480, "a matcher in seven lines", [
        "def follows(log, table):                     # table: the rows",
        "    at = 'start'",
        "    for m in log:                            # the events, oldest first",
        "        if m not in table[at].next:",
        "            return f'{m} is not allowed after {at}'",
        "        at = m                               # where the conversation is now",
        "    return 'follows' if table[at].may_stop else f'stopped early, after {at}'"], size=27)
    wrap(d, 80, 770, "The table says one thing more than a matcher can check: that each listed message can come. A log records what happened, "
         "not what was possible. So the table is a behaviour: everything a system may do, with the choices open at every moment.", F(R, 32), W - 160, TEXT)
    img.save(p)


@scene("truth", "Checking is filling in a truth table. Write the protocol's states down the side and the formulas across the top, and fill in each "
       "cell: does this formula hold here? Simple columns are read off the labels; recursive ones grow by a short loop until nothing changes. "
       "A formula holds of the protocol when its cell in the start row is true.")
def _(p):
    img, d = base("Chapter 5 · checking is filling in a truth table", "Images, six formulas, every state")
    rows = tex_rows(MORE["images-truth"])
    forms = [r for r in rows if r and r[0].startswith("(")]; table = [r for r in rows if r and not r[0].startswith("(")]
    code(d, 80, 230, 720, 420, "the formulas", [f"{a} {b}" for a, b in forms], size=24)
    y = 230
    for r in table:
        x = 840
        d.text((x, y), r[0][:30], font=F(B if y == 230 else R, 26), fill=AMBER if y == 230 else TEXT)
        for k, c in enumerate(r[1:]):
            d.text((x + 470 + k * 95, y), c, font=F(B, 28), fill=GREEN if c == "T" else RED if c == "F" else AMBER, anchor="ma")
        y += 60
    wrap(d, 80, 720, "Every check is a search for one path: an exists-claim holds when a witness exists; an always-claim holds when no "
         "counterexample exists. The searches come in two shapes: reach a state, or find a loop that stays somewhere forever. "
         "LeanFM's answers carry that path.", F(R, 32), W - 160, TEXT)
    img.save(p)

@scene("suggest", "You do not have to know what to ask. Without a formula, session_ctl builds properties from the protocol and decides each. For "
       "PlaceOrder, ten of twelve are proved. The two disproved ones are informative: some session can run forever is false, which is what we "
       "want; and no secret is ever sent is false, because the card number goes to the shop and the bank. A suggestion is a question, not a rule.")
def _(p):
    img, d = base("Chapter 10 · what should I ask?", "session_ctl without a formula")
    code(d, 80, 230, W - 160, 820, "suggested and decided", tex_listing(MORE["mcp-suggest"]).splitlines(), size=20)
    img.save(p)

@scene("next", "And at run time, session_next lists every step the protocol allows next, given the events of one session so far, with the event each "
       "must name as its cause. A server can call it to decide whether to accept an incoming message at all.")
def _(p):
    img, d = base("Chapter 10 · what may happen next?", "session_next")
    code(d, 80, 230, W - 160, 820, "the allowed next steps", wrapped(tex_listing(MORE["mcp-next"]).splitlines(), 115), size=22)
    img.save(p)

@scene("faithful", "A protocol becomes claims the same way. LeanFM tracks what is left to play, merges the states nobody could tell "
       "apart, and writes one row per state: a transition table. Read as code, it is a pattern matcher over the event stream. "
       "A system obeys these rows exactly when it behaves as the protocol says, and no set of C T L formulas can say more.")
def _(p):
    img, d = base("Chapters 5 to 7 · a protocol is a short list of claims", "Images: diagram, typestates, transition table")
    paste_fit(img, PNG["images"], (80, 240, 760, 620))
    paste_fit(img, PNG["images_ts"], (820, 240, W - 80, 620), frame=False)
    lines = [r["formula"] for r in IMG["rules"]["rules"]][:6]   # LeanFM's rows; no answer, no slide
    code(d, 80, 660, W - 160, 360, "session_ctl  faithful: rules", lines, size=26)
    img.save(p)


@scene("g_typestates", "PlaceOrder has " + DEEP["placeorder_rules"]["reading"].split(";")[0].split(": ", 1)[-1] + ". Each box is a typestate: a moment "
       "of the conversation as far as anyone can tell, the last message and whether it may stop. Two moments are merged only when nothing that can "
       "happen next could tell them apart. One rule per box, plus the start: eleven formulas that say everything the protocol says.")
def _(p):
    img, d = base("Chapter 6 · typestates and their rules", "PlaceOrder: " + DEEP["placeorder_rules"]["reading"].split(";")[0].split(": ", 1)[-1])
    paste_fit(img, PNG["placeorder_ts"], (80, 230, W - 80, 640), frame=False)
    code(d, 80, 670, W - 160, 380, "session_ctl  faithful: rules", DEEP["placeorder_rules"]["rules"][:7], size=21)
    img.save(p)

@scene("g_theorem", "Now the guarantee, stated plainly. A system satisfies these rules exactly when it has the protocol's moves at every moment: "
       "every message the protocol allows, the system can send, and nothing else. No move more, no move less, step after step. "
       "And that is the most any C T L can say: systems with the same moves satisfy exactly the same formulas, so no requirement written "
       "in this logic can tell them apart. The rules are not an approximation. They are the strongest observable statement there is.")
def _(p):
    img, d = base("Chapter 6 · the faithfulness theorem", "Obeys the rules  ⇔  has the protocol's moves at every moment")
    for k, (t, b, col) in enumerate([("no move more", "every message the system sends, the protocol allows here (the allNext part of each row)", GREEN),
                                     ("no move less", "every message the protocol allows here, the system can send (the someNext parts)", GREEN),
                                     ("nothing stronger exists", "systems with the same moves satisfy exactly the same CTL formulas (Browne, Clarke and Grumberg)", AMBER)]):
        y = 250 + k * 250
        d.rounded_rectangle([80, y, W - 80, y + 210], radius=16, fill=CARD, outline=col, width=3)
        d.text((120, y + 30), t, font=F(B, 42), fill=col); wrap(d, 120, y + 100, b, F(R, 32), W - 280, TEXT)
    img.save(p)

@scene("g_retry", "Here is what the guarantee costs, in one example. Retry's three tries leave no trace in the messages: an Ask after the first try "
       f"looks like an Ask after the third. So the rules must look ahead to tell them apart: lookahead {DEEP['retry_rules']['lookahead']}. LeanFM "
       f"also counts the hidden state in bits: Ask and Busy each need {DEEP['retry_rules']['hiddenBits']}. Put those bits in the message, "
       "or follow prev links, and the lookahead drops to zero. The guarantee tells you exactly what the wire must carry.")
def _(p):
    img, d = base("Chapter 7 · what the guarantee costs", f"Retry: lookahead {DEEP['retry_rules']['lookahead']}, {DEEP['retry_rules']['hiddenBits']} hidden bits")
    paste_fit(img, PNG["retry_ts"], (80, 230, W - 80, 640), frame=False)
    rows = [f"{b['label']:8}  {b['typestates']} typestate(s)   {b['bits']} bit(s)" for b in DEEP["retry_rules"]["bits"]]
    code(d, 80, 670, 900, 360, "session_ctl  bits", rows, size=24)
    wrap(d, 1020, 690, DEEP["retry_rules"]["reading"].split("Hidden state: ", 1)[-1], F(R, 28), W - 1100, TEXT)
    img.save(p)

@scene("g_unfaithful", "Faithfulness can be decided directly, without writing a single formula. Give LeanFM a candidate: here, a server that never "
       "answers NotFound. LeanFM pairs its states with the protocol's, finds the first place they differ, and shows the path: after GetImage, the "
       "protocol allows an Image or a NotFound, and the candidate only an Image. One pass over the candidate's steps.")
def _(p):
    img, d = base("Chapter 8 · is this implementation faithful?", "A server that cannot say NotFound")
    code(d, 80, 260, W - 160, 300, "session_ctl  faithful: candidate", wrapped(DEEP["images-no404"].splitlines(), 120), size=22)
    paste_fit(img, PNG["images_ts"], (480, 600, W - 480, 1040), frame=False)
    img.save(p)

@scene("g_branching", "And here is how strong observable means. Two systems: one chooses between a then b, and a then c, at the start; the other "
       "does a, then chooses b or c. Their logs are identical: a b, and a c. Yet they are not the same. After a, the first has already chosen, "
       "and the second has not. LeanFM tells them apart and says where: after a, one can do only b, the other b or c. Observable behaviour "
       "includes the choices still open, not only the messages that happened to be sent.")
def _(p):
    img, d = base("Chapter 8 · same logs, different behaviour", "a b | a c   versus   a (b | c)")
    code(d, 80, 260, W - 160, 380, "session_ctl  faithful: the classic pair", DEEP["branching"].splitlines(), size=26)
    wrap(d, 80, 690, "Systems with identical observable behaviour (the same messages and the same open choices at every moment) are "
         "indistinguishable: a claim true of one is true of the other, however differently they are built.", F(R, 34), W - 160, TEXT)
    img.save(p)

@scene("g_port", "That is what makes a port safe. To move a program from Rust to Zig, go through the specification: from Rust to the protocol and its "
       "claims, checked against the Rust program's logs, then from the specification to Zig, checked against the same claims. When both pass, "
       "nothing observable can tell the two programs apart, though they share no code.")
def _(p):
    img, d = base("Chapter 6 · the guarantee in practice", "Port through the specification")
    for k, (t, b) in enumerate([("Rust program", "its logs"), ("protocol + claims", "the specification"), ("Zig program", "the same claims")]):
        x = 80 + k * 600
        d.rounded_rectangle([x, 380, x + 520, 660], radius=16, fill=CARD, outline=GREEN if k == 1 else EDGE, width=3)
        d.text((x + 260, 470), t, font=F(B, 40), fill=TEXT, anchor="mm"); d.text((x + 260, 560), b, font=F(R, 30), fill=MUTED, anchor="mm")
        if k < 2: d.text((x + 560, 520), "→", font=F(B, 60), fill=AMBER, anchor="mm")
    d.text((W // 2, 800), "both checked against the same claims: nothing observable tells them apart", font=F(B, 36), fill=TEXT, anchor="mm")
    img.save(p)

@scene("where", "A where clause is about data, so it is checked on the run. Here is a log where the client pays twelve after a quote of ten. "
       "The order of messages is fine; the data is not. session_conform says exactly which event breaks which condition, and with which values.")
def _(p):
    img, d = base("Chapter 4 · where clauses, checked on the run", "where p.amount = q.price")
    code(d, 80, 240, W - 160, 300, "the log", DEEP["where"]["log"].splitlines(), size=22)
    d.text((80, 600), f"session_conform: {DEEP['where']['verdict']}", font=F(B, 44), fill=verdict_color(DEEP["where"]["verdict"]))
    wrap(d, 80, 680, DEEP["where"]["reading"], F(M, 28), W - 160, TEXT)
    img.save(p)

@scene("identity", "Real servers run many conversations at once. Each message names its session, and a where clause can say which earlier message "
       "a new session belongs to, so one log of interleaved events splits back into sessions, and each session is checked against its own "
       "protocol. GoServer is the large example: games, seats and moves, sessions that fork from a game and join back. Checked one session at a "
       "time, a protocol with over sixteen hundred typestates becomes many small checks.")
def _(p):
    img, d = base("Chapter 4 · identity: telling sessions apart", "Many conversations in one log")
    for k, (t, b) in enumerate([("each event names its session", "and its cause and prev links"), ("sessions fork and join", "a seat belongs to a person and to a game"),
                                ("checked one session at a time", "cost is the sum of the sessions, not their product")]):
        y = 260 + k * 250
        d.rounded_rectangle([80, y, W - 80, y + 210], radius=16, fill=CARD, outline=EDGE, width=2)
        d.text((120, y + 40), t, font=F(B, 40), fill=GREEN); d.text((120, y + 120), b, font=F(R, 32), fill=TEXT)
    img.save(p)

@scene("go_start", "So let us watch one. GoServer is running locally, a multiplayer Go server built from its own LeanFM specification. Like every "
       "project app, it logs its protocol events where LeanFM logs its own, in its project's logs folder, and server_logs lists that log by name: "
       f"GoServer slash events. We start a game between two server bots, {LIVE['game']['name']}.", True)
def _(n):
    steps = [{"cwd": "claude", "cmd": "server_logs", "status": 0, "out": [l[:118] for l in LIVE["listing"]][:4]},
             {"cwd": "claude", "cmd": f"POST /api/create_game  {LIVE['game']['name']}: 9x9, two bot seats  →  POST /api/start_game", "status": 0,
              "out": [f"{LIVE['game']['id']}: playing"]}]
    return terminal(steps, n, "GoServer, watched through LeanFM's MCP server")


def live_scene(k):
    st = LIVE["steps"][k]
    img, d = base(f"GoServer live · {st['at']} s in · session_conform  serverLog: GoServer/events  fromLine: {st['fromLine']}",
                  f"{st['verdict']}: lines {st['fromLine']} to {st['nextLine'] - 1}")
    paste_fit(img, os.path.join(DATA, f"live-{k}.png"), (80, 230, W - 80, 860))
    wrap(d, 80, 880, st["reading"], F(M, 28), W - 160, verdict_color(st["verdict"]))
    wrap(d, 80, 950, "newest: " + st["newest"][-1], F(M, 18), W - 160, MUTED, 4)
    return img

LIVE_TEXT = [
    "The bots play; each turn is a session of GoServer's Turn protocol: the server sends BotTurn, the bot answers BotMoveChosen with the same "
    "turn number, and the server applies it, or drops it as stale if the turn has moved on. LeanFM reads the new lines and checks them.",
    "The next poll starts where the last one ended, at its next line, so LeanFM follows the running server without rereading the log. "
    "Every turn so far follows the protocol; the sessions still open are the turns being played right now.",
    "The game grows on the board, and the log grows with it. Nothing here was simulated: these are the events the server wrote, as it "
    "wrote them, checked against the specification GoServer was built from.",
    "This is the same guarantee as before, applied to a running system: if GoServer ever played a turn the protocol does not allow, the "
    "next poll would name the session, the event, and what the protocol allowed instead."]
for _k in range(len(LIVE["steps"])):
    def _make(k):
        @scene(f"go_live{k}", LIVE_TEXT[k % len(LIVE_TEXT)])
        def _(p): live_scene(k).save(p)
    _make(_k)

@scene("cage_intro", "Now something measured. Our two guinea pigs stay home while we travel. An Arduino reads the water, the food and "
       "the temperature. A dispenser says when it runs. A webcam reports how much they move. Three devices and a hub are a protocol "
       "like any other: each reports until it is switched off.")
def _(p):
    img, d = base("Section 5.6 · the guinea pig cage", "examples/guinea-pigs")
    paste_fit(img, PNG["cover"], (80, 230, 1100, H - 60), frame=False)
    lines = CAGE["lean"].split("protocol GuineaPigCage", 1)[1].splitlines()
    code(d, 1140, 230, W - 1220, H - 290, "GuineaPigCage.leanfm", ["protocol GuineaPigCage" + lines[0]] + lines[1:], size=17)
    img.save(p)

@scene("cage_log", "Each event carries its measurements in its payload. The log is three days long, so Claude names it rather than sending "
       f"it, and the server reads it from disk. session_conform checks the order: {CAGE['order']['reading'].split(': ', 1)[-1]}", True)
def _(n):
    steps = T[8:9] + [{"cwd": "claude", "cmd": "session_conform  serverLog: devices  allowIncomplete: true", "status": 0,
                       "out": [f"{CAGE['order']['verdict']}: {CAGE['order']['reading']}"]}]
    return terminal(steps, n, "~/code/leanFM: the cage's log")

@scene("cage_words", "The measurements need claims of their own. Above and below compare a reading with a number; within and throughout "
       "look a number of seconds ahead. Every claim gets a margin: how far it is from failing, in the readings' own units. "
       "Positive is room to spare; negative is how far it failed.")
def _(p):
    img, d = base("Claims over measurements · check_signal", "Four new words, one margin")
    code(d, 80, 230, W - 160, 300, "the claims", [c["claim"] + "   ; " + c["says"] for c in CAGE["claims"]], size=24)
    code(d, 80, 570, W - 160, 450, "the margin, word by word", [
        "margin(above f c)  = reading(f) - c", "margin(below f c)  = c - reading(f)", "margin(not p)      = - margin(p)",
        "margin(and p q)    = min(margin(p), margin(q))    ; always, throughout: the least ahead",
        "margin(or p q)     = max(margin(p), margin(q))    ; within, possibly: the greatest ahead",
        "margin(on M)       = +infinity at an M, -infinity elsewhere"], size=26)
    img.save(p)

def cage_answer(k):
    c = CAGE["claims"][k]
    img, d = base(f"check_signal · serverLog: devices", c["says"])
    paste_fit(img, PNG[f"sig{k}"], (80, 240, W - 80, 760))
    d.text((80, 800), c["claim"], font=F(M, 30), fill=TEXT)
    d.text((80, 860), f"{c['verdict']}   margin {c['margin']}", font=F(B, 44), fill=verdict_color(c["verdict"]))
    ff = c["firstFailure"]
    if ff:   # the log's day 1 starts at 1794528000 (SignalChapterExample.t0)
        s = int(float(ff["t"])) - 1794528000
        when = f"first fails on day {s // 86400 + 1} at {s % 86400 // 3600:02d}:{s % 3600 // 60:02d}"
    else: when = "never fails"
    extra = f"; {c['cutShort']} moments had a window cut short by the end of the log" if c["cutShort"] else ""
    d.text((80, 930), when + extra, font=F(R, 30), fill=MUTED)
    return img

@scene("cage_temp", "check_signal answers each claim. The afternoon sun on the second day took the cage to twenty seven point one degrees: "
       "it fails, one point one over, and the first failing reading is marked in red.")
def _(p): cage_answer(0).save(p)

@scene("cage_food", "The bottle held, with seventy one millilitres to spare. The dispenser stuck once, on the third day, and ran twenty five "
       "minutes late: the one red mark among its runs.")
def _(p): cage_answer(2).save(p)

@scene("cage_motion", "The webcam claim fails only at the very last reading, and that is the log's fault, not the guinea pigs': the log ends "
       "during their quietest hour, so the two hour window after it runs past the end. check_signal counts such moments instead of guessing.")
def _(p): cage_answer(3).save(p)


@scene("shared", "Faithful rules can be large as trees, because a name repeats its parts. So formulas travel as s-expressions with labels: the "
       "first time a part appears it gets a label, after that it is referenced. The checker builds a graph of distinct parts and evaluates each "
       "once. That is why the cost is distinct subformulas times the model, not the size of the tree.")
def _(p):
    img, d = base("Chapter 8 · formulas that share", "#1= defines a part, #1# uses it again")
    code(d, 80, 230, W - 160, 820, "check_ctl over an inline draft", wrapped(tex_listing(MORE["mcp-checkctl"]).splitlines(), 115), size=22)
    img.save(p)

@scene("corpus", "Here is every protocol the repository carries, measured by LeanFM. Most have lookahead zero: the last message names the moment, "
       "and every rule is one step. The bounded retries pay in lookahead. GoServer is the large one, and it is large because of its "
       "parallel sessions, which is why logs are checked one session at a time.")
def _(p):
    img, d = base("Chapter 8 · the protocols LeanFM carries", "checker nodes, typestates, lookahead, rules")
    rows = tex_rows(MORE["corpus"]); y = 240
    for k, r in enumerate(rows[:16]):
        x = 100
        for j, c in enumerate(r[:6]):
            d.text((x, y), c[:26], font=F(B if k == 0 else M, 24), fill=AMBER if k == 0 else TEXT); x += [430, 230, 230, 230, 200, 200][j]
        y += 46
    img.save(p)

@scene("own", "LeanFM is held to the same standard. Its own MCP traffic, the agent, the host, the view and the server, is logged as events and "
       "checked against LeanFM's own protocol. " + MORE["own"]["reading"].split(";")[0].replace("LeanFMMcp: ", "") + ". That one session was "
       "written by an older build, before a fix to how the view labels its pages; the log keeps a true record, and the check reports it.")
def _(p):
    img, d = base("Chapter 11 · LeanFM's own protocol", "session_conform  serverLog: serve  protocolName: LeanFMMcp")
    d.text((80, 260), MORE["own"]["verdict"], font=F(B, 60), fill=verdict_color(MORE["own"]["verdict"]))
    wrap(d, 80, 360, MORE["own"]["reading"], F(M, 28), W - 160, TEXT)
    src = MORE["own"].get("source") or {}
    if src: d.text((80, 900), f"read on the server: {src.get('log')}  lines {src.get('fromLine')} to {src.get('lastLine')} of {src.get('logLines')}", font=F(M, 28), fill=MUTED)
    img.save(p)

@scene("linear", "All of it stays linear. Each word is one pass: a window is a sliding maximum or minimum, kept in a queue each reading "
       "enters and leaves once. Over a protocol, checking costs distinct subformulas times the model's size; over a log, words times "
       "readings. That is the rule for growing the logic: new words, never new costs.")
def _(p):
    img, d = base("Chapter 8 · deciding it", "New words, never new costs")
    for k, (t, cost, how) in enumerate([("a claim over a protocol", "O(subformulas × (states + steps))", "each distinct subformula once, over a DAG"),
                                        ("is a system faithful?", "O(steps)  with prev links", "the walk: one pass, no formulas at all"),
                                        ("a claim over a log", "O(words × readings)", "sliding windows, each reading in and out once")]):
        y = 260 + k * 250
        d.rounded_rectangle([80, y, W - 80, y + 210], radius=16, fill=CARD, outline=EDGE, width=2)
        d.text((120, y + 30), t, font=F(B, 38), fill=TEXT); d.text((120, y + 95), cost, font=F(M, 40), fill=GREEN)
        d.text((W - 120, y + 150), how, font=F(R, 28), fill=MUTED, anchor="ra")
    img.save(p)

@scene("lists", "A project keeps its requirements as a list, and each implementation choice as another. Every entry becomes claims, or "
       "says plainly that it does not yet: sorry, as in Lean, counted and shown, never silently assumed. Review happens in git. Claude "
       "writes, LeanFM checks, and a person reads the diff.")
def _(p):
    img, d = base("Chapter 9 · requirements and implementations", "Lists, sorry, and git")
    for k, (t, b, col) in enumerate([("requirement", "a statement: claims a machine decides", GREEN),
                                     ("implementation", "evidence: a log that follows the protocol, a test", BLUE),
                                     ("sorry", "not stated precisely yet: counted, shown, never assumed", AMBER)]):
        x = 80 + k * 600
        d.rounded_rectangle([x, 300, x + 560, 640], radius=16, fill=CARD, outline=col, width=3)
        d.text((x + 30, 330), t, font=F(B, 40), fill=col); wrap(d, x + 30, 410, b, F(R, 32), 500, TEXT)
    d.text((W // 2, 800), "Claude writes  ·  LeanFM checks  ·  a person reads the diff and commits", font=F(B, 40), fill=TEXT, anchor="mm")
    img.save(p)

@scene("outro", "Requirements Logic: protocols that say who sends what to whom, claims about what may and must happen next, and a server "
       "that checks both. Systems that behave the same on the wire cannot be told apart, so a port from one language to another is "
       "checked against the same claims. The book, the examples and the server are all in the repository.")
def _(p):
    img = Image.new("RGB", (W, H), NAVY); d = ImageDraw.Draw(img)
    paste_fit(img, PNG["cover"], (110, 60, W - 110, 760), frame=False)
    d.text((W // 2, 850), "github.com/rfielding/leanFM", font=F(B, 52), fill=GOLD, anchor="mm")
    d.text((W // 2, 930), "book/main.pdf  ·  examples/guinea-pigs  ·  make serve", font=F(M, 30), fill=GOLD, anchor="mm")
    img.save(p)


# More explanation for the scenes where the guarantees come from: appended to their narration.
EXTRA = {
 "st_intro": "Everything later rests on one idea: the protocol talks only about what can be seen between roles, the messages and their order. "
   "Nothing in it mentions a variable, a lock or a thread of any implementation. That is what lets the same text be a design, a type for "
   "each program, and a requirement that any log can be checked against.",
 "st_images": "Read it as a contract with three parts. The browser must send GetImage first. The server must then send exactly one answer. And "
   "the answer must say which request it answers, through its cause. A server that sent two answers, or none, or an answer to a request "
   "nobody made, is breaking the contract, and every one of those is visible in a log.",
 "st_placeorder": "Notice who decides each choice. The shop decides between a quote and sold out, because it sends the first message of both "
   "branches. The bank decides between charged and declined. The client decides nothing here; it only reacts. LeanFM checks that every "
   "choice has exactly one decider and that every role affected by a choice is told the outcome before it must act.",
 "st_loops": "The difference matters. In Poll, the moment after an Answer is the same moment every time round, so the checker needs no memory. "
   "In Retry, an Ask after the first try and an Ask after the third look identical on the wire, but they are different moments: one can be "
   "followed by another try, the other cannot. Keeping those apart is exactly the kind of work the guarantee will have to pay for.",
 "st_parallel": "Parallel is where size comes from: two branches of three moments each give thirteen moments when they interleave, and four "
   "branches multiply further. Include is where reuse comes from: the sign-in protocol is checked once, and every protocol that includes it "
   "gets its guarantees without repeating them.",
 "st_runs": "This is the meaning that everything else is measured against. Two systems that can produce exactly the same set of runs agree on "
   "every log. But as we will see, the strongest guarantee goes one step further than runs: it also cares which choices are still open at "
   "each moment.",
 "err_intro": "These are not style warnings. Each one describes a protocol that independent programs, each following only its own part, "
   "cannot carry out reliably. Catching them in the text means no one ever writes code against a design that cannot work.",
 "err_race": "In a real system this shows up as two messages crossing on the wire: a cancellation and a shipment, each side certain it acted "
   "first. No amount of careful coding fixes a race in the design; the design itself must say who decides.",
 "err_blind": "This is the distributed version of reading a variable you were never sent. The bank would have to guess, and a guess is a bug "
   "that only appears in production, on the branch nobody tested.",
 "err_borrow": "Causes are what let a checker match answers to requests when thousands of conversations interleave. A cause that names something "
   "its sender never received would make that matching meaningless, so LeanFM refuses it in the design.",
 "ttt_roles": "Read X's list from the top: send NewGame, send MoveX, then wait for XTurn or Result, and so on for up to five rounds. There is no "
   "state in which X may send two moves in a row, and no state in which it may ignore a Result. A program that only has these methods "
   "available cannot get the order wrong.",
 "proj_placeorder": "This is the bridge from the global protocol to code. Each role's typestate is derived, never written by hand, so it cannot "
   "disagree with the protocol. And because each state offers exactly the moves the protocol allows there, the guarantee starts inside the "
   "program, before any message is sent.",
 "err_jam": "So a protocol is checked twice over: once as a design, for races and blind choices, and once as a deployment, with real inboxes and "
   "every interleaving of deliveries. Only a protocol that passes both is one independent programs can actually keep.",
 "words": "Those four words are enough for almost every requirement in this book. Possibly says a thing can happen. Inevitably says it must. "
   "Always says it holds at every moment, on every path. And someAlways says some path keeps it forever.",
 "one_function": "Under the hood there is no special case. Every word unfolds, level by level, into this one function and negation. So "
   "understanding until, and the choice between every future and some future, is understanding the whole logic.",
 "faithful": "This is the central construction of the book. The protocol text, its diagram, its typestate graph and this table are four views of "
   "one thing, and LeanFM derives the last three from the first. Nothing is drawn or written separately that could drift.",
 "g_typestates": "Merging is what keeps the rules exact. If two moments were merged that some future could tell apart, the rules would allow a "
   "move at one that only belongs to the other. LeanFM merges only what no future can distinguish, by refining groups until nothing splits.",
 "g_theorem": "Put concretely: if a server satisfies these eleven formulas, then at every moment of every conversation it accepts exactly the "
   "messages PlaceOrder allows, and can send exactly the ones it allows. Any property you could ever ask of PlaceOrder in this logic, every "
   "request answered, no refund before a charge, holds of that server automatically. You check the rules once, and every consequence comes free.",
 "g_retry": "This is a design signal, not just a cost. Hidden bits are state that every participant must remember in step, and state that is "
   "remembered separately drifts. Putting the try number in the message, or linking each message to the one before, makes the state visible "
   "on the wire, where a log can check it.",
 "g_unfaithful": "Notice what kind of bug this is. Every message the candidate sends is allowed; a log of it would pass a simple matcher. What is "
   "missing is a move: the candidate can never say NotFound. Only a check of moves, not of logs, catches a missing capability.",
 "g_branching": "This is the precise sense in which the guarantee is strong. Comparing logs would call these two systems equal. The rules do not, "
   "because one of them makes a commitment earlier than the other, and a client talking to it can be stuck by that commitment. The guarantee "
   "is about what can be observed at every moment, including what is still possible.",
 "g_port": "And it works in the other direction too: a new implementation in any language is checked against the claims, not against the old "
   "code. The specification, not the original program, is the thing being preserved.",
 "where": "So the work divides cleanly. The protocol's control, which messages in which order, is pure session type and pure C T L, checked "
   "exactly. The data, what the messages carry, is checked on the run, where the values are.",
 "identity": "This is also why the checks scale. A product of parallel sessions is enormous as one model, but each session on its own is small, "
   "and the log tells you which events belong to which session.",
 "matcher": "And the two readings fit together: the matcher checks what did happen against the table, and the claims check what can happen.",
 "suggest": "This is how a design conversation usually goes in practice: ask what LeanFM can prove, look at what it cannot, and decide whether "
   "that is a bug or a fact about the design.",
 "linear": "Linear cost is what makes this usable while you design. A check that takes seconds can run on every edit, and an agent can run "
   "dozens of them in one conversation.",
}

# ── narration and assembly ──
def tts(text, path):
    run([PIPER, "--model", VOICE, "--length_scale", "1.08", "--output_file", path], input=text.encode(), stderr=subprocess.DEVNULL)
    with wave.open(path) as w: return w.getnframes() / w.getframerate()

LEAD, TAIL = 0.6, 1.0
only = os.environ.get("ONLY")
parts, voice_at, t = [], [], 0.0
for id, text, fn, animated in scenes:
    if only:
        if id == only:
            if animated:
                imgs = list(fn(240)); imgs[60].save(os.path.join(WORK, f"{id}_a.png")); imgs[-1].save(os.path.join(WORK, f"{id}_b.png"))
            else: fn(os.path.join(WORK, f"{id}.png"))
        continue
    wav = os.path.join(WORK, f"{id}.wav"); mp4 = os.path.join(WORK, f"{id}.mp4")
    text = text + (" " + EXTRA[id] if id in EXTRA else "")
    secs = LEAD + tts(text, wav) + TAIL
    fade = f"fade=t=in:st=0:d=0.4,fade=t=out:st={secs - 0.4:.3f}:d=0.4,format=yuv420p"
    if animated:
        n = int(secs * FPS)
        enc = subprocess.Popen(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-vf", fade, "-c:v", "libx264", "-preset", "medium",
                                "-crf", "20", mp4], stdin=subprocess.PIPE)
        for img in fn(n): enc.stdin.write(img.tobytes())
        enc.stdin.close()
        if enc.wait() != 0: sys.exit("encode failed")
    else:
        png = os.path.join(WORK, f"{id}.png"); fn(png)
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-t", f"{secs:.3f}",
             "-i", png, "-vf", fade, "-c:v", "libx264", "-preset", "medium", "-crf", "20", mp4])
    voice_at.append((wav, t + LEAD)); parts.append(mp4); t += secs
    print(f"{id}: {secs:.1f}s")
if only: sys.exit(0)
total = t
video = os.path.join(WORK, "video.mp4")
with open(os.path.join(WORK, "parts.txt"), "w") as f:
    for p in parts: f.write(f"file '{p}'\n")
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(WORK, "parts.txt"), "-c", "copy", video])
inputs = ["-i", video]; voices = []
for k, (wav, at) in enumerate(voice_at):
    inputs += ["-i", wav]; ms = int(at * 1000)
    voices.append(f"[{k + 1}:a]adelay={ms}|{ms},aformat=sample_rates=48000:channel_layouts=stereo[v{k}]")
mix = ";".join(voices) + ";" + "".join(f"[v{k}]" for k in range(len(voices))) + \
      f"amix=inputs={len(voices)}:normalize=0,apad,atrim=0:{total:.3f},alimiter=limit=0.95[a]"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *inputs, "-filter_complex", mix, "-map", "0:v", "-map", "[a]",
     "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", f"{total:.3f}", OUT])
print(f"wrote {OUT} ({total / 60:.1f} min)")
