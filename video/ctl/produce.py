"""What a diagram means: interaction diagrams turned into CTL, narrated and scored. Every diagram,
formula, verdict, session and timing on screen is read from data/, which fetch.py asked the running
LeanFM service; nothing is drawn by hand. Usage: produce.py [out.mp4]"""
import json, os, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data")
WORK = os.path.join(D, "build"); os.makedirs(WORK, exist_ok=True)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "leanfm-diagrams-as-ctl.mp4")
PIPER = f"{ROOT}/video/.conda/bin/piper"
VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
SCORE_DIR = f"{ROOT}/projects/Maqam/impl/zig/source"
SCORE = "synth.mq"
FPS, W, H = 30, 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85); HEAD = (32, 40, 54)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184)
RED = (248, 113, 113); BLUE = (125, 175, 255); VIOLET = (196, 160, 255); PINK = (244, 114, 182); CYAN = (34, 211, 238)
SESSION = [GREEN, BLUE, AMBER, VIOLET]
RULE = {"start": CYAN, "succession": GREEN, "order": BLUE, "cause": AMBER, "choice": VIOLET, "possible": PINK, "end": TEXT}
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_fonts = {}
def F(p, s):
    if (p, s) not in _fonts: _fonts[p, s] = ImageFont.truetype(p, s)
    return _fonts[p, s]
def run(cmd, **kw): subprocess.run(cmd, check=True, **kw)
def load(name): return json.load(open(os.path.join(DATA, f"{name}.json")))

trans = load("translation"); timings = load("timings"); flat = load("orders_flat")
types = load("orders_types"); playmove = load("goserver_playmove")
for name in ("orders", "place"):
    svg = os.path.join(WORK, f"{name}.svg")
    open(svg, "w").write(load(f"{name}_diagram")["svg"])
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-width", "1400", "-i", svg, os.path.join(WORK, f"{name}.png")])

# ── drawing ──
def base(tag, title=None, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN)
    d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    if title: d.text((80, 112), title, font=F(B, 50), fill=TEXT)
    if sub: d.text((80, 182), sub, font=F(R, 28), fill=AMBER)
    return img, d

KW = {"protocol", "structure", "where", "from", "to", "cause", "sessions", "include", "given", "with", "route", "status", "choice", "or", "message"}
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
                d.text((cx, yy), tok, font=f, fill=BLUE if tok in KW else AMBER if tok in ("prev", "cause", "requestId") else TEXT)
                cx += f.getlength(tok); tok = ""
            d.text((cx, yy), ch, font=f, fill=MUTED if ch == "/" else TEXT); cx += f.getlength(ch)
        yy += lh

def paste_fit(img, path, box):
    im = Image.open(path).convert("RGB")
    bw, bh = box[2] - box[0], box[3] - box[1]
    s = min(bw / im.width, bh / im.height)
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    x = box[0] + (bw - im.width) // 2; y = box[1] + (bh - im.height) // 2
    img.paste(im, (x, y)); ImageDraw.Draw(img).rectangle([x - 1, y - 1, x + im.width, y + im.height], outline=EDGE, width=2)

def wrap(d, x, y, text, font, width, fill, gap=8):
    line = ""
    for wd in text.split():
        t = (line + " " + wd).strip()
        if d.textlength(t, font=font) > width and line:
            d.text((x, y), line, font=font, fill=fill); y += font.size + gap; line = wd
        else: line = t
    if line: d.text((x, y), line, font=font, fill=fill); y += font.size + gap
    return y

def box(d, x, y, w, h, color, title, body, size=26):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=color, width=3)
    d.text((x + 22, y + 16), title, font=F(B, 30), fill=color)
    wrap(d, x + 22, y + 66, body, F(R, size), w - 44, TEXT)

# ── scenes ──
scenes = []
def scene(id, text, animated=False):
    def deco(fn): scenes.append((id, text, fn, animated)); return fn
    return deco

@scene("title", "What does an interaction diagram actually mean? Not roughly: exactly. Here is a way to find out. "
       "Turn every diagram into C T L, the language of what must and can happen next, and let a model checker decide it.")
def _(p):
    img, d = base("LEANFM · DIAGRAMS AS CTL")
    d.text((80, 300), "What does a diagram mean?", font=F(B, 92), fill=TEXT)
    d.text((80, 430), "Turn every interaction diagram into CTL, and let a model checker decide it.", font=F(R, 38), fill=AMBER)
    for i, (k, c, t) in enumerate([("full diagram", GREEN, "one session: follow TCP stream"),
                                   ("flat log", BLUE, "many sessions drawn over one another"),
                                   ("prev and cause", AMBER, "the chain every message carries"),
                                   ("CTL", PINK, "what must and can happen next, checked")]):
        d.text((120, 560 + i * 70), k, font=F(B, 34), fill=c); d.text((480, 560 + i * 70), t, font=F(R, 34), fill=TEXT)
    d.text((80, 960), "every diagram, formula, verdict and timing below is a LeanFM tool answer (video/ctl/data)", font=F(R, 24), fill=MUTED)
    img.save(p)

@scene("full", "Start with what a protocol definition draws. This diagram is one session. Like Wireshark's follow T C P stream, "
       "every message here belongs to the same conversation, so there is nothing to tell apart. Each actor's chain of messages "
       "is a simple line: it never forks and never joins. Choices and parallel branches live inside that one thread.")
def _(p):
    img, d = base("1 · A FULL DIAGRAM", "One session, one thread of typestate", "session_diagram of Orders · data/orders_diagram.json")
    paste_fit(img, os.path.join(WORK, "orders.png"), (80, 240, 1100, 1010))
    box(d, 1150, 260, 690, 330, GREEN, "full", "One session: follow TCP stream. Every message has the same session, so the id adds nothing. No actor's prev chain forks or joins.")
    box(d, 1150, 620, 690, 330, AMBER, "inside it", "Choices and parallel branches are inside one thread of typestate: the messages that are possible from each state.")
    img.save(p)

@scene("flat", "A real log is different. Here three orders are in flight at once, through the same server. This is a flat diagram: "
       "the union of every actor and every message. It is really three full diagrams drawn over one another, and the only "
       "things that can pull them apart are the links every message carries.")
def _(p):
    img, d = base("2 · A FLAT LOG", "Three full diagrams, drawn over one another", "session_conform of a log with no session ids · data/orders_flat.json")
    evs = flat["events_in"]; sess = {}
    for si, s in enumerate(flat["derivedSessions"]["sessions"]):
        for i in s["events"]: sess[i] = si
    for i, e in enumerate(evs):
        c = SESSION[sess.get(i, 0)]; y = 240 + i * 58
        d.rounded_rectangle([80, y, 1180, y + 46], radius=8, fill=CARD, outline=c, width=2); d.rectangle([80, y + 4, 88, y + 42], fill=c)
        d.text((104, y + 10), f"{i + 1:>2}  {e['label']}", font=F(B, 22), fill=c)
        fs = " ".join(f"{k}={v}" for part in ("headers", "path", "body") for k, v in (e.get(part) or {}).items() if k not in ("item",))
        d.text((480, y + 12), (f"cause {e['cause']}   " if e.get("cause") else "") + fs, font=F(M, 20), fill=TEXT)
    for si, s in enumerate(flat["derivedSessions"]["sessions"]):
        d.text((1230, 260 + si * 50), f"{s['key']}: {s['count']} events", font=F(B, 28), fill=SESSION[si])
    box(d, 1230, 440, 610, 300, BLUE, "flat", "The union of actors and messages over concurrent sessions. Only cause and prev untangle it.")
    d.text((1230, 770), flat["reading"][:60], font=F(R, 22), fill=GREEN)
    img.save(p)

@scene("wire", "So every message carries a chain: the previous message its sender sent, and, when it answers one, its cause. "
       "That is the abstract session type. But it has to be implemented on the wire, in ordinary fields. A where clause says "
       "which: here, a move's answer carries the request i d of the move it answers. The diagram's arrows are a picture "
       "of these equations.")
def _(p):
    img, d = base("3 · PREV AND CAUSE, ON THE WIRE", "The chain every message carries, implemented by fields", "the envelope LeanFM writes · GoServer's PlayMoveP")
    env = types.get("proto", ""); i = env.find("message Event")
    lines = [(l if len(l) <= 74 else l[:73] + "…") for l in env[i:].splitlines()[:10]]
    code(d, 80, 240, 1100, 470, "every logged message (data/orders_types.json)", lines, 19, mark=("cause =", "prev ="))
    code(d, 80, 740, 1760, 320, "GoServer: PlayMoveP (" + playmove["source"].split("/")[-1] + ")", playmove["text"].strip().splitlines(), 18, AMBER, mark=("requestId",))
    box(d, 1220, 240, 620, 470, AMBER, "the where clause", "A conjunct that relates a message to its cause implements the cause on the wire (p.requestId = m.requestId). Fresh, Link, given and with are shorthand for the same equations.")
    img.save(p)

RULES = [("start", "AX one of the first messages"), ("succession", "after a step, AX one of the next step's first messages"),
         ("order", "not E[ not prev U next ]: never next before prev"), ("cause", "no answer before its request; every request answered"),
         ("choice", "once a branch starts, no other branch ever happens"), ("possible", "EF every message"),
         ("end", "after a final message the session may end; every session ends")]
@scene("rules", "Now turn the structure into formulas, mechanically. Seven rules, all looking only forward in time. Start. Succession: "
       "after each step comes the next one. Order: never the next before the previous. Cause: no answer before its request, "
       "and every request answered. Choice: once a branch starts, no other branch. Every message possible. And every session can end.")
def _(p):
    img, d = base("4 · THE TRANSLATION", "Seven rules, future only", "reports/ctl-translation/translate.py")
    for i, (r, t) in enumerate(RULES):
        y = 260 + i * 100
        d.rounded_rectangle([80, y, 1840, y + 80], radius=12, fill=CARD, outline=RULE[r], width=2)
        d.text((110, y + 22), r, font=F(B, 32), fill=RULE[r]); d.text((440, y + 24), t, font=F(M, 28), fill=TEXT)
    img.save(p)

PF = trans["PlaceOrder"]["formulas"]
@scene("formulas", "Here is PlaceOrder: a quote, a payment, a charge at the bank, and two possible outcomes, or sold out. "
       "The translation gives forty formulas. Each one goes to the model checker, over the protocol's own state graph. "
       "Every one is proved. The diagram and the formulas say the same thing.", animated=True)
def formulas(n):
    for f in range(n):
        t = f / max(1, n - 1)
        img, d = base("5 · FORTY FORMULAS", "PlaceOrder, decided by session_ctl", "data/translation.json · data/place_diagram.json")
        paste_fit(img, os.path.join(WORK, "place.png"), (80, 240, 760, 1010))
        shown = int(len(PF) * min(1, t / 0.85))
        per = 20
        for k, fm in enumerate(PF[:shown]):
            col, row = k // per, k % per
            x, y = 800 + col * 530, 240 + row * 38
            ok = fm["verdict"] == "proved"
            d.text((x, y), "✓" if ok else "✗", font=F(B, 24), fill=GREEN if ok else RED)
            nm = fm["name"].replace(" before its request ", " before ")
            d.text((x + 28, y + 3), nm if len(nm) <= 50 else nm[:49] + "…", font=F(R, 18), fill=RULE[fm["rule"]])
        proved = sum(1 for fm in PF[:shown] if fm["verdict"] == "proved")
        d.text((800, 1020), f"{proved} of {len(PF)} proved", font=F(B, 30), fill=GREEN)
        yield img

def variant_rows():
    rows = []
    for proto in ("Orders", "PlaceOrder"):
        fs = trans[proto]["formulas"]
        for v in trans[proto]["variants"]:
            dis = [f for f, x in zip(fs, v["verdicts"]) if x == "disproved"]
            rej = [f for f, x in zip(fs, v["verdicts"]) if x == "rejected"]
            rows.append((proto, v["name"], dis, rej))
    return rows
@scene("variants", "Now break the protocol on purpose, in ways that are still valid protocols. Swap the order. Add a message at the end. "
       "Add a loop. Swap the bank's outcomes. Drop a message. Every broken version fails something, and the checker says "
       "exactly which promise it broke, with the path that shows it.")
def _(p):
    img, d = base("6 · BREAK IT ON PURPOSE", "Every broken variant fails a named formula", "the same formulas, decided on each variant · data/translation.json")
    for i, (proto, name, dis, rej) in enumerate(variant_rows()):
        y = 250 + i * 104
        d.rounded_rectangle([80, y, 1840, y + 88], radius=12, fill=CARD, outline=RED, width=2)
        d.text((104, y + 12), f"{proto}: {name}", font=F(B, 28), fill=TEXT)
        if dis:
            d.text((104, y + 50), f"{len(dis)} disproved, first: {dis[0]['name']}", font=F(R, 24), fill=RED)
        else:
            d.text((104, y + 50), f"{len(rej)} formulas name a message it no longer has (\"{rej[0]['name']}\")", font=F(R, 24), fill=AMBER)
    img.save(p)

@scene("channels", "And channels fall out for free. On a reliable channel, every message is followed by its successor, and nothing arrives "
       "before its prev. Declare the channel lossy, and the first constraint goes away. Declare it reordering, and the second goes. "
       "A protocol over U D P is the same diagram, with fewer constraints. This part is a proposal, not yet built.")
def _(p):
    img, d = base("7 · CHANNELS ARE CONSTRAINTS", "Same diagram, fewer constraints", "proposed: selfhost.session.ctl-translation, selfhost.session.physics")
    box(d, 80, 250, 1760, 200, GREEN, "lossless (reliable, stream, http)", "AG( arrive(A,B,1) → AF arrive(A,B,2) )   every message is followed by its successor: removed on a lossy channel", 28)
    box(d, 80, 480, 1760, 200, BLUE, "in order", "AG( arrive(A,B,2) → once arrive(A,B,1) )   or, future only, ¬E[ ¬arrive 1 U arrive 2 ]: removed on a reordering channel", 28)
    box(d, 80, 710, 1760, 200, AMBER, "bounded", "at most c messages sent and not yet arrived: the queue's capacity", 28)
    img.save(p)

T_ = timings
@scene("speed", "Is it slow? Measured: the small protocols take about a millisecond per formula. GoServer, with almost four thousand "
       "states, takes a fifth of a second per question, and most of that is building its state graph once. Decided in a batch "
       "over one graph, a formula costs a few hundredths of a second.")
def _(p):
    img, d = base("8 · IS IT SLOW?", "Measured on this machine", "data/timings.json")
    rows = [("PlaceOrder", f"{T_['place_formulas']} formulas", f"{T_['place_seconds']:.2f} s total, {1000 * T_['place_seconds'] / T_['place_formulas']:.0f} ms each"),
            ("GoServer, parse", "", f"{T_['goserver_parse_s']:.2f} s"),
            ("GoServer, one formula", f"{T_['goserver_states']} states", f"{T_['goserver_one_formula_s']:.2f} s (mostly the graph)"),
            ("GoServer, batch", f"{T_['goserver_batch_n']} formulas, one graph", f"{T_['goserver_batch_s']:.2f} s, {(T_['goserver_batch_s'] - T_['goserver_one_formula_s']) / max(1, T_['goserver_batch_n'] - 1) * 1000:.0f} ms each after the graph")]
    for i, (a, b, c) in enumerate(rows):
        y = 260 + i * 130
        d.rounded_rectangle([80, y, 1840, y + 110], radius=12, fill=CARD, outline=EDGE, width=2)
        d.text((110, y + 34), a, font=F(B, 34), fill=TEXT); d.text((700, y + 38), b, font=F(R, 30), fill=MUTED); d.text((1150, y + 38), c, font=F(B, 30), fill=GREEN)
    img.save(p)

@scene("answer", "Where it could get slow is the flat log: checking many sessions at once multiplies their states. So split the work the way "
       "the diagrams already split it. Model check each full diagram: small, exact, every promise proved. Replay the flat log: "
       "cause and prev untangle the threads, and each thread is checked against its full diagram, in time linear in the log.")
def _(p):
    img, d = base("9 · THE ANSWER", "Model check the full diagrams, replay the flat logs")
    box(d, 80, 260, 860, 520, GREEN, "full diagrams: model check", "One session each, nested diagrams plugged in by given and with. Small state graphs, exact meaning: every formula decided.", 30)
    box(d, 980, 260, 860, 520, BLUE, "flat logs: replay", "Many sessions at once. Cause and prev untangle the threads; each thread is checked against its full diagram. Linear in the log.", 30)
    d.text((80, 840), "where clauses stay symbolic: identity equations are which messages belong together, not values", font=F(R, 30), fill=AMBER)
    img.save(p)

OUTRO = "Turn the diagrams into C T L, and you know exactly what they mean. Then argue about how it should behave."
@scene("outro", OUTRO)
def _(p):
    img, d = base("LEANFM · DIAGRAMS AS CTL")
    d.text((80, 340), "Exactly what it means.", font=F(B, 92), fill=TEXT)
    d.text((80, 470), "Then argue about how it should behave.", font=F(R, 42), fill=AMBER)
    d.text((80, 600), "reports/ctl-translation · selfhost.session.correlation · selfhost.session.ctl-translation", font=F(M, 28), fill=MUTED)
    img.save(p)

# ── narration, pictures, music bed ──
def tts(text, path):
    run([PIPER, "--model", VOICE, "--output_file", path], input=text.encode(), stderr=subprocess.DEVNULL)
    with wave.open(path) as w: return w.getnframes() / w.getframerate()

LEAD, TAIL, MUSIC_TAIL = 0.8, 1.4, 12.0
parts, voice_at, t = [], [], 0.0
for id, text, fn, animated in scenes:
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
