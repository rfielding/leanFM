"""A tutorial on Lean as a programming language and on the LeanFM language written in it: narrated
and scored. Every snippet on screen is a region of Tour.lean, a file in mistakes/ or protocols/, or a
file of examples/orders; every result, error, diagram, verdict and count is read from data/, which
fetch.py asked Lean (`lake env lean --json`) and the running LeanFM service. Nothing is typed in by
hand. Usage: produce.py [out.mp4]; ONLY=<scene> writes that scene's still to build/."""
import json, os, re, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data")
WORK = os.path.join(D, "build"); os.makedirs(WORK, exist_ok=True)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "leanfm-lean-tutorial.mp4")
PIPER = f"{ROOT}/video/.conda/bin/piper"
VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
SCORE_DIR = f"{ROOT}/projects/Maqam/impl/zig/source"
SCORE = "synth.mq"
FPS, W, H = 30, 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85); HEAD = (32, 40, 54)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184)
RED = (248, 113, 113); BLUE = (125, 175, 255); VIOLET = (196, 160, 255); PINK = (244, 114, 182); CYAN = (34, 211, 238)
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_fonts = {}
def F(p, s):
    if (p, s) not in _fonts: _fonts[p, s] = ImageFont.truetype(p, s)
    return _fonts[p, s]
def run(cmd, **kw): subprocess.run(cmd, check=True, **kw)
def load(name): return json.load(open(os.path.join(DATA, f"{name}.json")))

TOUR_FILE = "video/lean-tutorial/Tour.lean"
TOUR = open(os.path.join(ROOT, TOUR_FILE)).read().splitlines()
MSGS = {}
for m in load("tour"): MSGS.setdefault(m["line"], []).append(m)
MIS = load("mistakes"); ST = load("stats"); GR = load("grammar")
OT = load("orders_text"); OCHK = load("orders_check"); CON = load("constructs"); LK = load("lookup")
FML = load("formula"); OCTL = load("orders_ctl"); OCONF = load("orders_conform"); RQ = load("reqcheck"); EXP = load("orders_explained")

def region(name):
    """The lines of Tour.lean's scene `name`, each with its 1-based line number."""
    i = TOUR.index(f"--@scene {name}")
    j = TOUR.index("--@end", i)
    return [(k + 1, TOUR[k]) for k in range(i + 1, j)]

def svg_png(name, svg, width=1500):
    p = os.path.join(WORK, f"diag_{name}.svg"); open(p, "w").write(svg)
    png = os.path.join(WORK, f"diag_{name}.png")
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-width", str(width), "-i", p, png])
    return png

# ── drawing ──
def base(tag, title=None, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN)
    d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    if title: d.text((80, 112), title, font=F(B, 48), fill=TEXT)
    if sub: d.text((80, 178), sub, font=F(R, 27), fill=AMBER)
    return img, d

KW = {"def", "structure", "inductive", "where", "deriving", "match", "with", "fun", "let", "mut", "for", "in", "do", "if", "then",
      "else", "return", "theorem", "example", "by", "namespace", "end", "open", "instance", "partial", "private", "import", "syntax",
      "macro_rules", "protocol", "choice", "or", "par", "and", "rec", "include", "sessions", "from", "to", "cause",
      "route", "status", "at", "version", "requirements", "implementation", "refines", "hint", "conform", "test", "sorry",
      "throw", "pure", "continue", "have", "unfold", "omega", "decide", "rfl", "of", "AG", "AF", "EF", "AX", "EX", "EU", "not", "implies"}

def lean_line(d, x, y, line, f, maxw=None):
    """One line of Lean, coloured: comments muted, strings amber, keywords blue, #commands violet."""
    cx = x
    def put(t, c):
        nonlocal cx
        d.text((cx, y), t, font=f, fill=c); cx += f.getlength(t)
    if line.lstrip().startswith(("/-", "-/")) or line.rstrip().endswith("-/") and "/-" in line:
        put(line, MUTED); return cx
    i = 0
    while i < len(line):
        if line.startswith("--", i): put(line[i:], MUTED); break
        if line[i] == "⊨":  # not in the mono font
            d.text((cx, y), "⊨", font=F(R, f.size), fill=CYAN); cx += f.getlength("="); i += 1; continue
        ch = line[i]
        if ch == '"':
            j = i + 1
            while j < len(line) and line[j] != '"': j += 2 if line[j] == "\\" else 1
            put(line[i:j + 1], AMBER); i = j + 1; continue
        if ch == "#" and i + 1 < len(line) and line[i + 1].isalpha():
            j = i + 1
            while j < len(line) and line[j].isalpha(): j += 1
            put(line[i:j], VIOLET); i = j; continue
        if ch.isalnum() or ch in "_«»":
            j = i
            while j < len(line) and (line[j].isalnum() or line[j] in "_«»!?'."): j += 1
            tok = line[i:j]
            put(tok, BLUE if tok in KW else TEXT); i = j; continue
        put(ch, CYAN if ch in "←→⊨·λ|" else TEXT); i += 1
    return cx

def panel(d, x, y, w, h, head, color=GREEN):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=EDGE, width=2)
    d.rounded_rectangle([x, y, x + w, y + 50], radius=14, fill=HEAD); d.rectangle([x, y + 36, x + w, y + 50], fill=HEAD)
    d.text((x + 20, y + 11), head, font=F(B, 23), fill=color)

def fit(t, f, avail):
    if f.getlength(t) <= avail: return t
    while f.getlength(t + "…") > avail and len(t) > 4: t = t[:-1]
    return t + "…"

def result_text(m):
    first = m["text"].split("\n")[0]; more = len(m["text"].split("\n")) - 1
    return ("⇒ " if m["severity"] == "information" else "⚠ ") + first + (f"  (+{more} lines)" if more else "")

def layout(rows, results, x, w, rx, size):
    """Rows to draw at this font size: each code line, and each result beside its line when it fits
    there, otherwise on a row of its own under it."""
    f = F(M, size); out = []
    for n, line in rows:
        out.append(("code", line, None))
        for m in (results or {}).get(n, []):
            t = result_text(m); end = x + 20 + f.getlength(line) + 2 * size
            at = max(rx or 0, end)
            if at + f.getlength(t) <= x + w - 20: out[-1] = ("code", line, (at, t, m))
            else: out.append(("result", None, (x + 20 + 3 * f.getlength(" "), t, m)))
    return out

def code(d, x, y, w, h, head, lines, size=None, color=GREEN, results=None, rx=None):
    """A code panel. `lines` are strings or (lineNo, string); with `results`, each line Lean printed
    something for gets that output beside it (from column `rx`), as an editor's info view shows it,
    or under it when it does not fit. The font shrinks until the longest line and every row fit."""
    panel(d, x, y, w, h, head, color)
    rows = [l if isinstance(l, tuple) else (None, l) for l in lines]
    size = size or 26
    longest = max((len(l) for _, l in rows), default=1)
    size = max(12, min(size, int((w - 40) / (max(longest, 1) * 0.61))))
    while True:
        lay = layout(rows, results, x, w, rx, size)
        if 64 + len(lay) * int(size * 1.42) <= h - 10 or size <= 12: break
        size -= 1
    f = F(M, size); lh = int(size * 1.42); yy = y + 64
    for kind, line, res in lay:
        if kind == "code": lean_line(d, x + 20, yy, line, f)
        if res:
            at, t, m = res
            c = RED if m["severity"] == "error" else AMBER if m["severity"] == "warning" else GREEN
            d.text((at, yy), fit(t, f, x + w - 20 - at), font=f, fill=c)
        yy += lh
    return yy

def wrap(d, x, y, text, font, width, fill, gap=8):
    for para in text.split("\n"):
        line = ""
        for wd in para.split(" "):
            t = (line + " " + wd) if line else wd
            if d.textlength(t, font=font) > width and line:
                d.text((x, y), line, font=font, fill=fill); y += font.size + gap; line = wd
            else: line = t
        d.text((x, y), line, font=font, fill=fill); y += font.size + gap
    return y

def box(d, x, y, w, h, color, title, body, size=24, mono=False):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=color, width=3)
    d.text((x + 20, y + 14), title, font=F(B, 27), fill=color)
    # the body shrinks until it fits inside the box (measured on a scratch image)
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    while size > 14 and wrap(probe, 0, y + 60, body, F(M if mono else R, size), w - 40, TEXT, 6) > y + h - 10: size -= 1
    return wrap(d, x + 20, y + 60, body, F(M if mono else R, size), w - 40, TEXT, 6)

def mistake(d, x, y, w, h, fname, keep_source=None, err_lines=6, size=20):
    """A file of mistakes/ and the first error Lean printed for it."""
    mi = MIS[fname]; src = mi["source"].rstrip("\n").splitlines()
    if keep_source: src = [l for l in src if keep_source(l)]
    e = mi["errors"][0]
    err = [l for l in e["text"].split("\n") if l.strip() and not l.startswith("Hint:")][:err_lines]
    if not src: sys.exit(f"{fname}: no source line left to show")
    longest = max(len(l) for l in src)
    size = max(15, min(size, int((w - 40) / (longest * 0.61))))
    f = F(M, size); lh = int(size * 1.42)
    per = int((w - 40) / (size * 0.61))
    err = [c for l in err for c in ([l[k:k + per] for k in range(0, len(l), per)] or [""])]
    sh = 64 + len(src) * lh + 10
    code(d, x, y, w, sh, f"mistakes/{fname}", src, size=size, color=RED)
    ey = y + sh + 14
    d.rounded_rectangle([x, ey, x + w, y + h], radius=14, fill=(40, 20, 24), outline=RED, width=2)
    d.text((x + 20, ey + 12), f"Lean, line {e['line']}: error", font=F(B, 22), fill=RED)
    yy = ey + 50
    for l in err:
        d.text((x + 20, yy), fit(l, f, w - 40), font=f, fill=TEXT); yy += lh

def chunks(s, n):
    """Words of s in lines of at most n characters."""
    out, line = [], ""
    for wd in s.split(" "):
        if len(line) + len(wd) + 1 > n and line: out.append(line); line = wd
        else: line = (line + " " + wd).strip()
    return out + ([line] if line else [])

def paste_fit(img, path, bx, frame=True):
    src = Image.open(path).convert("RGBA")
    im = Image.new("RGB", src.size, BG); im.paste(src, (0, 0), src)
    bw, bh = bx[2] - bx[0], bx[3] - bx[1]
    s = min(bw / im.width, bh / im.height, 1.6)
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    x = bx[0] + (bw - im.width) // 2; y = bx[1] + (bh - im.height) // 2
    img.paste(im, (x, y))
    if frame: ImageDraw.Draw(img).rectangle([x - 1, y - 1, x + im.width, y + im.height], outline=EDGE, width=2)

def tour_scene(p, tag, title, sub, name, rx=1010, mist=None, mist_keep=None, err_lines=6, codew=None):
    """A scene of Tour.lean: the region and what Lean printed for each line, with an optional mistake."""
    img, d = base(tag, title, sub)
    lines = region(name)
    cw = codew or (1760 if not mist else 1060)
    code(d, 80, 230, cw, 790, f"{TOUR_FILE}, lines {lines[0][0]}–{lines[-1][0]}", lines, results=MSGS, rx=80 + rx)
    if mist: mistake(d, 80 + cw + 30, 230, 1760 - cw - 30, 790, mist, mist_keep, err_lines, 22)
    img.save(p)

# ── scenes ──
scenes = []
def scene(id, text):
    def deco(fn): scenes.append((id, text, fn)); return fn
    return deco

@scene("title", "This is a tutorial in two parts. First, Lean as a programming language: not proofs, but functions, records, "
       "lists, errors and files, the parts of Lean that LeanFM is actually written in. Second, the LeanFM language, which is "
       "written in Lean: message types, protocols, C T L, and the lists of requirements and implementations. Every snippet you "
       "will see is a real file, and every result is what Lean or LeanFM printed for it.")
def _(p):
    img, d = base("LEANFM · A LEAN TUTORIAL")
    d.text((80, 250), "Lean as a programming language,", font=F(B, 80), fill=TEXT)
    d.text((80, 350), "and the LeanFM language written in it", font=F(B, 64), fill=GREEN)
    rows = [("part 1", BLUE, "def, structure, inductive, match, Option, Except, do, IO, classes, #guard, proofs as types"),
            ("part 2", AMBER, "message types, protocol statements, where clauses, versions, CTL, requirements and implementations")]
    for i, (k, c, t) in enumerate(rows):
        d.text((120, 520 + i * 80), k, font=F(B, 34), fill=c); d.text((330, 524 + i * 80), t, font=F(R, 30), fill=TEXT)
    d.text((80, 940), f"snippets: {TOUR_FILE}, video/lean-tutorial/mistakes, protocols, examples/orders · results: lake env lean --json and the LeanFM service",
           font=F(R, 22), fill=MUTED)
    img.save(p)

@scene("why", f"Most people meet Lean in mathematics, writing proofs. LeanFM uses it mostly as a programming language. "
       f"Across its {ST['files']} Lean files there are {ST['def']} definitions, {ST['match']} pattern matches and {ST['do-arrow']} "
       f"arrows in do blocks, against {ST['theorem']} theorems. Its tests are {ST['#guard']} guards that run while the file compiles. "
       "Three commands run everything. lake build compiles the project. lake env lean, on a file, checks it and prints every hash eval. "
       "And lake env lean dash dash run runs its main function, like a script.")
def _(p):
    img, d = base("PART 1 · LEAN AS A PROGRAMMING LANGUAGE", "Mostly programs, checked by a compiler that can also prove",
                  f"measured over {ST['files']} files, {ST['lines']} lines ({ST['boundary']})")
    items = [("def", ST["def"], BLUE), ("match … with", ST["match"], BLUE), ("← in do blocks", ST["do-arrow"], BLUE),
             ("#guard tests", ST["#guard"], GREEN), ("structure", ST["structure"], BLUE), ("partial def", ST["partial def"], BLUE),
             ("by native_decide", ST["native_decide"], VIOLET), ("theorem", ST["theorem"], VIOLET)]
    top = max(v for _, v, _ in items)
    for i, (k, v, c) in enumerate(items):
        y = 250 + i * 62
        d.text((80, y + 6), k, font=F(M, 26), fill=TEXT)
        d.rounded_rectangle([420, y, 420 + max(8, int(560 * v / top)), y + 44], radius=6, fill=c)
        d.text((430 + max(8, int(560 * v / top)), y + 6), str(v), font=F(B, 26), fill=c)
    cmds = [("lake build", "compile the project (its lakefile names the targets)"),
            ("lake env lean File.lean", "check one file; print every #eval, warning and error"),
            ("lake env lean --run File.lean", "run the file's main : IO Unit, like a script")]
    panel(d, 1120, 250, 720, 480, "running Lean")
    for i, (c, t) in enumerate(cmds):
        d.text((1145, 320 + i * 130), c, font=F(M, 27), fill=AMBER); wrap(d, 1145, 362 + i * 130, t, F(R, 24), 670, TEXT)
    d.text((80, 800), "A file compiles top to bottom: a name must be defined before it is used.", font=F(B, 30), fill=GREEN)
    img.save(p)

@scene("def", "A definition names a value. double takes a natural number and returns one; the types follow the colons. "
       "Hash eval asks Lean to run it, and the result appears beside the line, as an editor shows it. A function is a value too: "
       "twice takes a function and applies it two times. You can pass a named function, an anonymous fun, or the dot shorthand, "
       "where the dot stands for the argument. Types are checked before anything runs: a string where a number is expected does not compile.")
def _(p): tour_scene(p, "1 · DEFINITIONS AND FUNCTIONS", "def: a name, typed arguments, a result", "⇒ is what #eval printed for that line",
                     "def", rx=560, mist="TypeMismatch.lean", err_lines=6)

@scene("structure", "A structure is a record. Pay has an amount and a currency, with a default. Deriving Repr lets Lean print one, "
       "and B E Q lets two be compared with double equals. Build one with braces, read a field with a dot, and copy one with a "
       "change using with. Nothing is mutated: the copy is a new value. LeanFM's message types are structures like this one.")
def _(p): tour_scene(p, "2 · STRUCTURES", "structure: a record with named, typed fields", "the message types of a protocol are structures", "structure", rx=700)

@scene("inductive", "An inductive type lists its cases, and each case carries its own data. This is LeanFM's requirement pointer: "
       "a protocol, a formula over a protocol, or sorry. A function over it gives one equation per case, matching the case by name. "
       "Lean checks that every case is handled: leave one out, and the file does not compile. The error names the missing case.")
def _(p): tour_scene(p, "3 · INDUCTIVE TYPES AND MATCH", "inductive: a fixed set of cases; match: one equation each",
                     "LeanFM/Session/Text.lean has this Pointer type", "inductive", rx=620, mist="MissingCase.lean", err_lines=3)

@scene("option", "Lean has no null. A value that may be missing has type Option: some value, or none. priceOf returns an Option, "
       "because the item may not be on the list. To use the number inside, you must say what happens when it is missing: with getD "
       "and a default, or with a match. Forget, and add one to an Option as if it were a number, and the program does not compile.")
def _(p): tour_scene(p, "4 · OPTION: NO NULL", "Option α: some value, or none", "a missing value is in the type, so it cannot be forgotten",
                     "option", rx=640, mist="OptionNotNat.lean", err_lines=2)

@scene("except", "Pure code has no exceptions either. A computation that can fail returns Except: ok with a result, or error with a reason. "
       "Inside a do block, the left arrow unwraps a result, and the first error stops the whole block and becomes its answer. "
       "Here, order parses the quantity, looks up the price and multiplies. Every LeanFM tool works this way: a refusal is a value "
       "with its reason, never a crash.")
def _(p): tour_scene(p, "5 · EXCEPT AND DO", "Except ε α: .ok result, or .error reason", "← unwraps; the first error ends the block", "except", rx=760)

@scene("collections", "Lists are written in square brackets. map changes every element, filter keeps some, and fold left combines them, "
       "here into a sum. The pipe passes a value on, so a chain reads left to right. An Array is a list that grows at the end. "
       "Indexing with a question mark returns an Option, because the index may be out of range; with a bang, it is a promise that it is not.")
def _(p): tour_scene(p, "6 · LISTS AND ARRAYS", "map, filter, foldl, and |> to chain them", "· stands for the argument", "collections", rx=820)

@scene("loops", "Lean also has loops, written in do notation. Let mut, a for loop, continue, return. It looks imperative, but it is "
       "still a pure function: let mut gives a name a new value at each step, and Id dot run says this block has no effects at all. "
       f"LeanFM uses Id dot run do {ST['Id.run do']} times, wherever a loop reads more clearly than a fold.")
def _(p): tour_scene(p, "7 · LOOPS IN DO NOTATION", "let mut, for, continue, return: still pure", "Id.run do … runs a block with no effects", "loops", rx=760)

@scene("strings", "Strings. Split on a separator, join with one, test a prefix. S bang before a string interpolates: anything in braces "
       "is evaluated and printed. include str reads a whole file into a string when the file compiles; LeanFM's tests use it to "
       "load protocol files. Here it reads the book's Orders example and finds its protocol line.")
def _(p): tour_scene(p, "8 · STRINGS", 's!"…{x}…" interpolates; include_str reads a file at compile time', "LeanFM's tests load protocols this way", "strings", rx=900)

@scene("io", "Effects show in the type. main has type I O unit: it may read files and print. Inside, the left arrow runs an effect and "
       "names its result. This main reads the Orders requirements file and prints its requirement lines. Hash eval runs it here; "
       "lake env lean dash dash run would run it as a program. A pure function cannot do this: its type says it has no effects.")
def _(p):
    img, d = base("9 · IO: EFFECTS IN THE TYPE", "main : IO Unit may read files and print", "the output is what Lean printed when it ran main")
    lines = region("io")
    ch = 64 + len(lines) * int(26 * 1.42) + 20
    code(d, 80, 230, 1760, ch, f"{TOUR_FILE}, lines {lines[0][0]}–{lines[-1][0]}", lines, size=26)
    printed = [m for n, _ in lines for m in MSGS.get(n, [])]
    if not printed: sys.exit("io: Lean printed nothing for main; re-run fetch.py")
    out = printed[0]["text"].split("\n")
    y = 230 + ch + 30
    code(d, 80, y, 1760, 1020 - y, "Lean prints", out, size=22, color=AMBER)
    img.save(p)

@scene("names", "Names live in namespaces. Shop dot tax is tax inside Shop; open makes it available without the prefix. "
       "A function named Pay dot total can be called with a dot on any Pay, so p dot total means Pay dot total of p. "
       "And French quotes make a keyword usable as a name: a message's from field is spelled with them, because from is a Lean keyword.")
def _(p): tour_scene(p, "10 · NAMESPACES AND DOT NOTATION", "Shop.tax, open, p.total, and «from»", "LeanFM's own names are LeanFM.Session.Text.readText and so on", "names", rx=930)

@scene("classes", "A type class is a shared interface, and an instance teaches a type to meet it. Here Role learns To String, so it "
       "can appear in an interpolated string. Deriving writes instances for you: To Json and From Json turn a Quote into J S O N and "
       "back. This is how every LeanFM tool answer becomes J S O N for M C P clients.")
def _(p): tour_scene(p, "11 · TYPE CLASSES AND DERIVING", "instance: teach a type an interface; deriving: let Lean write it",
                     "ToJson / FromJson carry every MCP answer", "classes", rx=900)

@scene("partial", "Lean wants every function to finish, because a function that loops forever could prove anything. "
       "countdown is accepted: its argument shrinks on every call. collatz is not: nobody knows whether it always ends, and "
       "Lean says it cannot show termination. Marking it partial runs it anyway, and gives up proving things about it. "
       f"LeanFM has {ST['partial def']} partial definitions, mostly parsers and graph walks.")
def _(p): tour_scene(p, "12 · TERMINATION AND PARTIAL", "every def must end, or be marked partial", "partial: it runs, and nothing can be proved about it",
                     "partial", rx=660, mist="Termination.lean", err_lines=5)

@scene("guard", "Hash guard is a test that runs while the file compiles. If its expression is false, compilation fails, with the expression "
       f"in the error. LeanFM has {ST['#guard']} of them. So make check is mostly Lean compiling test files: if they compile, they passed.")
def _(p): tour_scene(p, "13 · #guard: TESTS THAT ARE COMPILE ERRORS", "a false #guard stops the build", f"{ST['#guard']} #guards in LeanFM",
                     "guard", rx=900, mist="Guard.lean", err_lines=3)

@scene("proofs", "Now proofs, as a programmer meets them. A statement is a type, and a proof is a value of that type. "
       "double of twenty one equals forty two is proved by r f l: Lean computes both sides. by decide checks a decidable fact by "
       "computation. double add is true for every a and b, which no test can show; the tactic omega does the arithmetic. "
       "LeanFM proves C T L verdicts the same way, with native decide.")
def _(p): tour_scene(p, "14 · PROOFS ARE VALUES", "a statement is a type; a proof is a value of it", "rfl and decide compute; omega does arithmetic", "proofs", rx=1060)

@scene("carry", "The idea worth stealing: a structure field can be a proof. A Price has cents, and a proof that cents is positive. "
       "Its constructor is private, so outside this file the only way to make one is Price dot make, which checks first. "
       "Then every Price that ever exists is positive, and the theorem never zero says so with no runtime check. "
       "Try to build a zero price directly, and the proof fails at compile time. LeanFM's linked logs and checked messages are built like this.")
def _(p): tour_scene(p, "15 · STRUCTURES THAT CARRY PROOFS", "no Price exists unless 0 < cents", "LeanFM/Session/Linked.lean and ConstructorsExample.lean",
                     "carry", rx=640, mist="ZeroPrice.lean", err_lines=3)

@scene("sorry", "Sorry is a hole. It stands for a proof you have not written. Lean accepts the file, warns that the declaration uses sorry, "
       "and keeps counting. LeanFM borrows the idea for requirements: a requirement that does not convert to C T L yet is a sorry, "
       "kept on the list, warned about, never counted as met.")
def _(p):
    img, d = base("16 · SORRY: AN ADMITTED HOLE", "accepted, warned about, never forgotten", "LeanFM's requirement lists use sorry the same way")
    lines = region("sorry")
    code(d, 80, 240, 1760, 200, f"{TOUR_FILE}, lines {lines[0][0]}–{lines[-1][0]}", lines, size=28, results=MSGS, rx=1180)
    box(d, 80, 500, 860, 420, AMBER, "in Lean", "theorem … := sorry compiles. Every use is a warning, so the holes stay visible until each is filled.", 28)
    box(d, 980, 500, 860, 420, GREEN, "in LeanFM", '"Refunds within 30 days" => sorry "PlaceOrder has no Refund message yet"; is on the requirements list, counted and warned about; with STRICT=1 it fails the gate.', 28)
    img.save(p)

@scene("syntax", "Last, the feature that makes LeanFM possible: Lean's grammar can be extended. Two lines add a new kind of term, twice bang, "
       "and say what it means. LeanFM does the same at the command level: protocol, requirements and implementation are new commands, "
       "added with a parser and an elaborator. That is why a LeanFM file is a Lean file. And it is why the words must not be reserved: "
       "LeanFM's requirements command starts with a non reserved symbol, so requirements stays an ordinary name everywhere else.")
def _(p):
    img, d = base("17 · EXTENDING LEAN'S GRAMMAR", "syntax and macro_rules add a term; LeanFM adds commands", "how protocol, requirements and implementation exist")
    lines = region("syntax")
    code(d, 80, 230, 1760, 300, f"{TOUR_FILE}, lines {lines[0][0]}–{lines[-1][0]}", lines, size=28, results=MSGS, rx=900)
    code(d, 80, 570, 1760, 300, f"{GR['file']}, line {GR['line']}", GR["body"] + [""] + GR["cmd"], size=22, color=AMBER)
    d.text((80, 900), "nonReservedSymbol … true: a command led by a word that stays an identifier (Project.Requirements.requirements still works)",
           font=F(R, 25), fill=MUTED)
    img.save(p)

# ── part 2 ──
proto_lines = OT["text"].split("requirements {")[0].rstrip().splitlines()
req_map = "requirements {" + OT["text"].split("requirements {")[1]
# the requirements line of the computed summary, e.g. "requirements: 5 convert to CTL, 5 met"
REQ_MET = re.search(r"^requirements: .*?(\d+) met", EXP["summary"], re.M).group(1)
REQ_SORRY = [re.match(r'\s*"([^"]+)"', l).group(1) for l in req_map.splitlines() if "=> sorry" in l]
@scene("leanfm", "Part two: the LeanFM language. A LeanFM file is a Lean file. It imports LeanFM's syntax, declares message types as structures, "
       "and writes each protocol with the protocol command. This is the book's Orders example. A client creates an order; the shop "
       "quotes it or says it is sold out; a quoted order is paid, the bank charges the card, and the client gets a receipt or a refusal. "
       "On the right, the diagram LeanFM draws from exactly this text.")
def _(p):
    img, d = base("PART 2 · THE LEANFM LANGUAGE", "A LeanFM file is a Lean file", f"{OT['file']} · the diagram is session_diagram's")
    body = [l for l in proto_lines if l.strip()]
    code(d, 80, 230, 1000, 800, OT["file"], body, size=17)
    paste_fit(img, svg_png("orders", load("orders_diagram")["svg"], 1200), (1110, 230, 1840, 1030))
    img.save(p)

@scene("statements", "Read one message line from left to right. An optional id and a colon, so later lines can refer to it. The label, which "
       "names the message type. From one role to another. Cause names the earlier message this one answers. Route and status say how it "
       "travels over H T T P, and change no verdict. Where states a condition over the payloads. Choice says exactly one branch happens. "
       "LeanFM checks it: every role can tell which branch it is in, and nothing gets stuck.")
def _(p):
    img, d = base("18 · A MESSAGE, PIECE BY PIECE", "id: Label from A to B cause x route … status … where …;", "session_check · examples/orders/Requirements.leanfm")
    pay = next(l.strip() for l in proto_lines if "p: Pay" in l)
    quote = next(l.strip() for l in proto_lines if "q: Quote" in l)
    code(d, 80, 230, 1760, 170, "two lines of PlaceOrder", [quote, pay], size=28)
    parts = [("q:", "an id, so later lines can name this message"), ("Quote", "the label: the message type, a structure"),
             ("from Shop to Client", "sender and receiver: roles of the protocol"), ("cause o", "the earlier message this one answers"),
             ("route / status", "how it travels over HTTP; changes no verdict"), ("where p.amount = q.price", "a condition over the payloads, typed by Lean"),
             ("choice { … } or { … }", "exactly one branch happens; the sender of its first message decides")]
    for i, (k, t) in enumerate(parts):
        y = 430 + i * 66
        d.text((100, y), k, font=F(M, 27), fill=AMBER); d.text((620, y + 2), t, font=F(R, 27), fill=TEXT)
    wrap(d, 80, 900, f"session_check: {OCHK['verdict']}. {OCHK['reading']}", F(B, 28), 1760, GREEN)
    img.save(p)

@scene("where", "A where clause is not a string. When the file compiles, it becomes a Lean proposition over the typed payloads. "
       "So a misspelt field is a Lean error, at compile time, before any run or log: here amont instead of amount. "
       "At run time, conformance evaluates the same condition over the values each event logged.")
def _(p):
    img, d = base("19 · WHERE CLAUSES ARE TYPED BY LEAN", "a misspelt field is a compile error", "lake env lean on the file below")
    mistake(d, 80, 230, 1760, 760, "WhereTypo.leanfm", err_lines=4, size=24)
    img.save(p)

@scene("constructs", "The other statement forms, in one small checked file. Par runs branches at the same time, and what follows waits for both. "
       "Rec names a loop, and continue jumps back to it. Include reuses an earlier protocol with its roles renamed. Sessions says "
       "any number of independent copies run, as a server handles requests. And Compact at Primary is an event, something a role "
       f"does on its own. Session check reads it with {'no issues' if not CON['issues'] else str(len(CON['issues'])) + ' issues'}.")
def _(p):
    img, d = base("20 · par, rec, include, sessions, events", "every statement form, in one checked file", "video/lean-tutorial/protocols/Constructs.leanfm")
    body = [l for l in CON["text"].splitlines() if l.strip() and not l.startswith("--")]
    code(d, 80, 230, 1000, 800, "protocols/Constructs.leanfm", body, size=18)
    paste_fit(img, svg_png("constructs", CON["svg"], 1200), (1110, 230, 1840, 900))
    wrap(d, 1110, 930, f"session_check: {CON['verdict']}. {CON['reading']}", F(B, 25), 730, GREEN)
    img.save(p)

cp = LK["compat"]
FIRST, LAST = cp["upgradePath"]["order"][0], cp["upgradePath"]["order"][-1]
@scene("versions", "Protocols change. A file keeps every version still deployed, oldest first. Version two may also answer Missing. "
       "When the file compiles, Lean checks that there is a clean upgrade path: an order to upgrade the roles one at a time, with every "
       "mixed deployment still able to finish. "
       f"Here the {FIRST.lower()} must upgrade first; a {LAST.lower()} that upgrades first could send Missing to "
       f"an old {FIRST.lower()} that cannot read it. Session compat names the order and the step that gets stuck.")
def _(p):
    img, d = base("21 · VERSIONS", "a change without a clean upgrade path is a compile error", "session_compat · protocols/Lookup.leanfm")
    body = [l for l in LK["text"].splitlines() if l.strip() and not l.startswith("--")]
    code(d, 80, 230, 1760, 330, "protocols/Lookup.leanfm", body, size=24)
    wrap(d, 80, 600, cp["reading"], F(B, 30), 1760, GREEN)
    for i, iss in enumerate(cp["issues"]):
        wrap(d, 80, 690 + i * 130, iss, F(M, 22), 1760, AMBER if "cannot" in iss else TEXT)
    img.save(p)

@scene("ctl", "Requirements are stated in C T L, written as S expressions: an operator, then its arguments, in parentheses. "
       "Explain formula parses one, however it is spaced, and formats it back: a canonical line, and an indented form that breaks "
       "long parts one argument per line. It also gives the formula in notation and reads it in English: on every path, always, if "
       "an order was created, then on every path, eventually a receipt, a declined payment or sold out.")
def _(p):
    img, d = base("22 · CTL AS S-EXPRESSIONS", "explain_formula parses and formats a formula", "sexpr and sexprPretty, from the LeanFM service")
    code(d, 80, 230, 1760, 170, "what was sent (spacing and line breaks as typed)", FML["input"].split("\n"), size=24, color=MUTED)
    code(d, 80, 420, 1760, 110, "sexpr", [FML["sexpr"]], size=21)
    code(d, 80, 550, 1060, 240, "sexprPretty", FML["sexprPretty"].split("\n"), size=22)
    box(d, 1170, 550, 670, 240, BLUE, "notation", FML["notation"], 28)
    wrap(d, 80, 820, "reading: " + FML["reading"], F(R, 25), 1760, TEXT)
    img.save(p)

@scene("decide", "LeanFM decides a formula over the protocol's state graph, every reachable state, not a sample. "
       f"Every order is answered: {OCTL[0]['verdict']}. Can the bank be charged after sold out? {OCTL[1]['verdict'].capitalize()}"
       f"{': no path does it' if OCTL[1]['verdict'] == 'disproved' else ''}. And a real run's log can be checked against the protocol: "
       f"these {len(OCONF['events'])} events, in one session, {'follow it' if OCONF['verdict'] == 'conforms' else OCONF['verdict']}.")
def _(p):
    img, d = base("23 · DECIDING A FORMULA, CHECKING A RUN", "session_ctl over every state; session_conform over a log", "PlaceOrder")
    for i, c in enumerate(OCTL):
        y = 230 + i * 200; col = GREEN if c["verdict"] == "proved" else RED
        d.rounded_rectangle([80, y, 1840, y + 180], radius=14, fill=CARD, outline=col, width=3)
        d.text((104, y + 16), f"{c['verdict']}:  {c['notation']}", font=F(B, 32), fill=col)
        d.text((104, y + 66), c["formula"], font=F(M, 22), fill=MUTED)
        ev = c["path"]; note = ev.get("note", "") if isinstance(ev, dict) else ""
        wrap(d, 104, y + 104, c["reading"].split(": ", 1)[-1] + (f"   ({note})" if note else ""), F(R, 23), 1700, TEXT)
    y = 650
    code(d, 80, y, 1760, 370, f"session_conform · {OCONF['log']}",
         [f"{e.get('id','')}: {e['label']} from {e['from']} to {e['to']}" + (f" cause {e['cause']}" if e.get("cause") else "") for e in OCONF["events"]] +
         ["", f"-- {OCONF['verdict']}: {OCONF['reading']}"], size=22)
    img.save(p)

@scene("requirements", "Every requirements file ends in a list: a requirement's name, and a pointer to what it means. A protocol name means "
       "exactly that conversation. P, models, and a formula means that formula, decided over P. And sorry means it does not convert to "
       "C T L yet: refunds cannot be stated until the protocol has a refund message. A pointer to a protocol that does not exist is a "
       "Lean error, not a sorry.")
def _(p):
    img, d = base("24 · THE REQUIREMENTS LIST", '"name" => pointer;  a protocol, P ⊨ (formula), or sorry', f"the end of {OT['file']}")
    rl = [l for l in req_map.splitlines() if l.strip()]
    code(d, 80, 230, 1760, 64 + len(rl) * 30 + 16, "the map", rl, size=19)
    y = 230 + 64 + len(rl) * 30 + 40
    mistake(d, 80, y, 1760, 1030 - y, "UnknownProtocol.leanfm", keep_source=lambda l: "=>" in l, err_lines=1, size=19)
    img.save(p)

@scene("checked", "Each entry converts to C T L and is decided. Here is what each requirement of the Orders file requires, as LeanFM writes "
       f"the formula and reads it back, with its verdict. {REQ_MET} are met. "
       + " ".join(f"{n} is a sorry, kept on the list." for n in REQ_SORRY))
def _(p):
    img, d = base("25 · WHAT EACH REQUIREMENT REQUIRES", "the CTL, its reading, its verdict", EXP["source"])
    panel(d, 80, 230, 1760, 800, "requirements, checked")
    f = F(M, 19); lh = 26; y = 294; per = int((1760 - 120) / (19 * 0.61))
    for l in EXP["requirements"].splitlines():
        if not l.strip(): y += 10; continue
        ind = len(l) - len(l.lstrip()); body = l.strip()
        c = AMBER if ind == 0 else GREEN if body.startswith("->") and "sorry" not in body else PINK if body.startswith("->") else \
            BLUE if not body.startswith(("on ", "it ", "the ", "sorry")) else TEXT
        for k, part in enumerate(chunks(body, per - ind // 4 * 2)):
            d.text((100 + ind * 10 + (24 if k else 0), y), part, font=f, fill=c); y += lh
    img.save(p)

impl = OT["impl"]; impl_block = "implementation" + impl.split("\nimplementation", 1)[1]
@scene("implementation", "An implementation names the requirements it implements, and holds what should stay out of them: behaviour no client "
       "can see, and choices like the language. Refines says the shop as built, with its database, must still meet every formula. "
       "Each requirement gets evidence: a conforming log, a named test, or sorry. It can add C T L of its own, and hints for whoever "
       "writes the code, often an L L M. make requirements check converts and decides every entry.")
def _(p):
    img, d = base("26 · AN IMPLEMENTATION", "evidence, its own CTL, and hints", f"{OT['impl_file']} · make requirements-check")
    il = [l for l in impl_block.splitlines() if l.strip()]
    yy = code(d, 80, 230, 1760, 64 + len(il) * 31 + 20, OT["impl_file"], il, size=22)
    box(d, 80, yy + 40, 1000, 1030 - yy - 40, GREEN, "status, computed", EXP["summary"], 25, mono=True)
    out = (RQ["stdout"] + RQ["stderr"]).strip()
    box(d, 1110, yy + 40, 730, 1030 - yy - 40, AMBER, f"make requirements-check: exit {RQ['exit']}", out, 25, mono=True)
    img.save(p)

@scene("outro", "That is the whole loop. Write Lean and LeanFM in the same files. Lake env lean compiles them, running every guard and "
       "typing every where clause. The LeanFM tools draw, check and decide. And the requirements gate keeps the list honest: met, "
       "specified, or sorry. Temporal Lean: statements about behaviour over time, checked like Lean checks a proof.")
def _(p):
    img, d = base("LEANFM · A LEAN TUTORIAL")
    d.text((80, 260), "Write it in Lean. Check it like a proof.", font=F(B, 72), fill=TEXT)
    steps = [("lake env lean", "compile: types, matches, #guards, where clauses, versions"), ("session_* tools", "draw, check, decide CTL, conform logs"),
             ("make requirements-check", "every entry: met, specified, sorry, or failing")]
    for i, (k, t) in enumerate(steps):
        d.text((120, 450 + i * 90), k, font=F(M, 36), fill=AMBER); d.text((700, 456 + i * 90), t, font=F(R, 32), fill=TEXT)
    d.text((80, 900), "Tour.lean · book: Requirements and Implementations · leanfm://language/session-reference", font=F(M, 26), fill=MUTED)
    img.save(p)

# ── narration, pictures, music bed ──
def tts(text, path):
    run([PIPER, "--model", VOICE, "--output_file", path], input=text.encode(), stderr=subprocess.DEVNULL)
    with wave.open(path) as w: return w.getnframes() / w.getframerate()

LEAD, TAIL, MUSIC_TAIL = 0.8, 1.4, 8.0
only = os.environ.get("ONLY")
parts, voice_at, t = [], [], 0.0
for id, text, fn in scenes:
    if only:
        if only in (id, "all"): fn(os.path.join(WORK, f"{id}.png"))
        continue
    wav = os.path.join(WORK, f"{id}.wav"); mp4 = os.path.join(WORK, f"{id}.mp4")
    secs = LEAD + tts(text, wav) + TAIL + (MUSIC_TAIL if id == "outro" else 0)
    fade = f"fade=t=in:st=0:d=0.4,fade=t=out:st={secs - 0.4:.3f}:d=0.4,format=yuv420p"
    png = os.path.join(WORK, f"{id}.png"); fn(png)
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-t", f"{secs:.3f}",
         "-i", png, "-vf", fade if parts else fade.replace("fade=t=in:st=0:d=0.4,", ""), "-c:v", "libx264", "-preset", "medium",
         "-tune", "stillimage", "-crf", "18", mp4])
    voice_at.append((wav, t + LEAD)); parts.append(mp4); t += secs
    print(f"{id}: {secs:.1f}s")
if only: sys.exit(0)
total = t

# the score, its sympathetic strings at 0.9995 (the source file is unchanged)
SYM_FROM, SYM_TO = "sym mic decay 0.9999", "sym mic decay 0.9995"
mq = open(os.path.join(SCORE_DIR, SCORE)).read()
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
