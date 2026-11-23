"""Session separation, narrated, scored by maqam-live (the Zig implementation, synth.mq, rendered offline).
Every protocol, diagram, session, problem and note on screen is read from data/, which fetch.py asked the
running LeanFM service; nothing is drawn by hand. Usage: produce.py [out.mp4]"""
import json, os, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data")
WORK = os.path.join(D, "build"); os.makedirs(WORK, exist_ok=True)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "leanfm-session-separation.mp4")
PIPER = f"{ROOT}/video/.conda/bin/piper"
VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
MAQAM = f"{ROOT}/projects/Maqam/impl/zig/source"
SCORE = "synth.mq"
FPS, W, H = 30, 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85); HEAD = (32, 40, 54)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184)
RED = (248, 113, 113); BLUE = (125, 175, 255); VIOLET = (196, 160, 255)
SESSION = [GREEN, BLUE, AMBER, VIOLET]
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_fonts = {}
def F(p, s):
    if (p, s) not in _fonts: _fonts[p, s] = ImageFont.truetype(p, s)
    return _fonts[p, s]

def run(cmd, **kw): subprocess.run(cmd, check=True, **kw)
def load(name): return json.load(open(os.path.join(DATA, f"{name}.json")))

# ── what the service answered ──
orders_three, orders_reuse, orders_remint = load("orders_three"), load("orders_reuse"), load("orders_remint")
orders_served = load("orders_served")
site_check, site_unbound, site_two, site_cross = load("site_check"), load("site_unbound"), load("site_two"), load("site_cross")
lend = load("lend_check")
for name in ("orders", "site"):
    svg = os.path.join(WORK, f"{name}.svg")
    open(svg, "w").write(load(f"{name}_diagram")["result"]["svg"])
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-width", "1400", "-i", svg, os.path.join(WORK, f"{name}.png")])

def fields(e):
    out = []
    for part in ("headers", "path", "query", "body"):
        for k, v in (e.get(part) or {}).items():
            if k in ("item", "user", "verbose"): continue
            out.append(f"{k}={v}")
    return " ".join(out)

def session_of(q):
    """position -> (session index, session key) from derivedSessions"""
    m = {}
    for si, s in enumerate(q["result"]["derivedSessions"]["sessions"]):
        for p in s["events"]: m[p] = (si, s["key"])
    return m

def why(evs, i, marks):
    """why the event joins the session it does: its cause, or the Link it carries, or it starts one"""
    e = evs[i]
    links = [f for f in marks.get(e["label"], {}).get("link", []) if f"{f}=" in fields(e)]
    if e.get("cause"): return f"answers {e['cause']} (cause)"
    if links:
        f = links[0]; v = [x for x in fields(e).split() if x.startswith(f + "=")][0]
        return f"carries Link {v}"
    return "starts a session"

# the marks as the protocol text declares them (Fresh / Link fields per message)
def marks_of(lean):
    out, cur = {}, None
    for line in lean.splitlines():
        if line.startswith("structure "): cur = line.split()[1]; continue
        if cur and ":" in line and line.startswith("  "):
            f, t = line.strip().split(":", 1)
            for kind in ("Fresh", "Link"):
                if kind in t: out.setdefault(cur, {}).setdefault(kind.lower(), []).append(f.strip())
    return out

# ── drawing ──
def base(tag, title=None, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN)
    d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    if title: d.text((80, 112), title, font=F(B, 50), fill=TEXT)
    if sub: d.text((80, 182), sub, font=F(R, 28), fill=AMBER)
    return img, d

KW = {"protocol", "structure", "where", "from", "to", "cause", "sessions", "include", "given", "with", "route", "status"}
def code(d, x, y, w, h, head, lines, size=22, color=GREEN):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=EDGE, width=2)
    d.rounded_rectangle([x, y, x + w, y + 52], radius=14, fill=HEAD); d.rectangle([x, y + 38, x + w, y + 52], fill=HEAD)
    d.text((x + 22, y + 12), head, font=F(B, 24), fill=color)
    f = F(M, size); lh = int(size * 1.4); yy = y + 68
    for line in lines:
        if line.startswith("!"):
            line = line[1:]; d.rectangle([x + 4, yy - 3, x + w - 4, yy + lh - 5], fill=(22, 58, 46))
        cx, tok = x + 22, ""
        for ch in line + " ":
            if ch.isalnum() or ch == "_": tok += ch; continue
            if tok:
                col = BLUE if tok in KW else AMBER if tok in ("Fresh", "Link") else TEXT
                d.text((cx, yy), tok, font=f, fill=col); cx += f.getlength(tok); tok = ""
            d.text((cx, yy), ch, font=f, fill=TEXT); cx += f.getlength(ch)
        yy += lh

def paste_fit(img, path, box, crop=None):
    im = Image.open(path).convert("RGB")
    if crop: im = im.crop(crop)
    bw, bh = box[2] - box[0], box[3] - box[1]
    s = min(bw / im.width, bh / im.height)
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    x = box[0] + (bw - im.width) // 2; y = box[1] + (bh - im.height) // 2
    img.paste(im, (x, y)); ImageDraw.Draw(img).rectangle([x - 1, y - 1, x + im.width, y + im.height], outline=EDGE, width=2)

def wrap(d, x, y, text, font, width, fill, gap=8):
    words, line = text.split(), ""
    for wd in words:
        t = (line + " " + wd).strip()
        if d.textlength(t, font=font) > width and line:
            d.text((x, y), line, font=font, fill=fill); y += font.size + gap; line = wd
        else: line = t
    if line: d.text((x, y), line, font=font, fill=fill); y += font.size + gap
    return y

def verdict(d, x, y, w, q, ok_word="conforms"):
    good = q["result"]["verdict"] in ("conforms", "ok")
    col = GREEN if good else RED
    f = F(B, 24); text = q["text"]
    while d.textlength(text, font=f) > w - 40: text = text[:-2]
    d.rounded_rectangle([x, y, x + w, y + 64], radius=12, fill=CARD, outline=col, width=3)
    d.text((x + 20, y + 16), text if text == q["text"] else text[:-1] + "…", font=f, fill=col)

def row(d, x, y, w, i, e, color, dim=False, extra=""):
    fg = MUTED if dim else TEXT
    d.rounded_rectangle([x, y, x + w, y + 44], radius=8, fill=CARD, outline=color if color else EDGE, width=2 if color else 1)
    if color: d.rectangle([x, y + 4, x + 8, y + 40], fill=color)
    d.text((x + 20, y + 9), f"{i + 1:>2}", font=F(M, 22), fill=MUTED)
    d.text((x + 62, y + 9), e["label"], font=F(B, 22), fill=color or fg)
    d.text((x + 262, y + 9), f"{e['from']}→{e['to']}", font=F(M, 20), fill=fg)
    d.text((x + 452, y + 9), (f"cause {e['cause']}  " if e.get("cause") else "") + fields(e), font=F(M, 20), fill=fg)
    if extra: d.text((x + w - 10 - d.textlength(extra, font=F(R, 20)), y + 10), extra, font=F(R, 20), fill=color or MUTED)

# ── scenes: (id, narration, draw(path) for a still, or frames(n) for an animation) ──
scenes = []
def scene(id, text, animated=False):
    def deco(fn): scenes.append((id, text, fn, animated)); return fn
    return deco

ORDERS = orders_three["arguments"]["lean"]; SITE = site_check["arguments"]["lean"]
O_EVS = orders_three["arguments"]["events"]; O_SESS = session_of(orders_three); O_MARKS = marks_of(ORDERS)

@scene("title", "Session separation in Lean F M. A server log interleaves many conversations, and usually it does not "
       "say which event belongs to which. Lean F M separates them using only what the protocol declares. "
       "")
def _(p):
    img, d = base("LEANFM · SESSIONS", None)
    d.text((80, 300), "Session separation", font=F(B, 96), fill=TEXT)
    d.text((80, 430), "One log. No session ids. The protocol says who belongs together.", font=F(R, 40), fill=AMBER)
    for i, (k, c) in enumerate([("cause", "an answer belongs to its request"),
                                ("Fresh", "a message mints a session id"),
                                ("Link", "a later message names the id it was given"),
                                ("given / with", "an included task is handed its parent's id")]):
        d.text((120, 560 + i * 70), k, font=F(B, 34), fill=SESSION[i]); d.text((420, 560 + i * 70), c, font=F(R, 34), fill=TEXT)
    d.text((80, 960), "every view below is a LeanFM tool answer (video/sessions/data)",
           font=F(R, 24), fill=MUTED)
    img.save(p)

@scene("log", "Here is a log of an order service. Twelve events, three orders in flight at once, and no session ids. "
       "Like Wireshark following a TCP stream by its addresses and ports, we want to follow each order. "
       "But nothing here is a port number. The only identity is what the protocol declares.")
def _(p):
    img, d = base("1 · THE LOG", "Twelve events, interleaved, unlabelled", "session_conform input: video/sessions/data/orders_three.json")
    for i, e in enumerate(O_EVS): row(d, 80, 250 + i * 58, 1760, i, e, None)
    img.save(p)

@scene("protocol", "This is the protocol. Created mints the order id: it is marked Fresh, in a header. GetOrder names it "
       "again in its path: it is marked Link. And each answer names its request as its cause. "
       "The diagram is generated from this text by Lean F M.")
def _(p):
    img, d = base("2 · THE PROTOCOL", "Identity is declared in the text", "Fresh mints a session id, Link names one, cause ties an answer to its request")
    lines = ORDERS.splitlines()
    code(d, 80, 240, 900, 780, "Orders (IdentityTests.lean fixture)",
         [("!" if ("Fresh" in l or "Link" in l or "cause" in l) else "") + l for l in lines], 20)
    paste_fit(img, os.path.join(WORK, "orders.png"), (1010, 240, 1840, 1020))
    img.save(p)

@scene("separate", "Now Lean F M reads the log in order. CreateOrder can start a session. Created names its request as "
       "its cause, and mints an order id. GetOrder carries that id as a Link, so it joins the session that minted it. "
       "Nothing else joins events: not equal values, not timing. Three sessions fall out, and each one is replayed "
       "against the protocol. The verdict: twelve events in three sessions, all conforming.", animated=True)
def separate(n):
    order = list(range(len(O_EVS)))
    lane_x, lane_w = 1000, 840
    keys = [s["key"] for s in orders_three["result"]["derivedSessions"]["sessions"]]
    t_reveal = [(0.06 + 0.8 * k / len(order)) for k in order]
    for f in range(n):
        t = f / max(1, n - 1)
        img, d = base("3 · SEPARATION", "Following each order through the log", "derivedSessions from session_conform · positions, keys and verdict as returned")
        for si, key in enumerate(keys):
            y0 = 250 + si * 235
            d.rounded_rectangle([lane_x, y0, lane_x + lane_w, y0 + 215], radius=14, fill=(18, 23, 31), outline=SESSION[si], width=2)
            d.text((lane_x + 18, y0 + 10), f"session: {key}", font=F(B, 24), fill=SESSION[si])
        filled = [0] * len(keys)
        for i, e in enumerate(O_EVS):
            si, _ = O_SESS[i]
            shown = t >= t_reveal[i]
            y = 250 + i * 58
            row(d, 80, y, 880, i, e, SESSION[si] if shown else None, dim=not shown)
            if shown:
                k = min(1.0, (t - t_reveal[i]) / 0.05)
                ty = 250 + si * 235 + 46 + filled[si] * 40
                cx = int(80 + (lane_x + 18 - 80) * k); cy = int(y + (ty - y) * k)
                d.text((cx, cy), e["label"], font=F(B, 22), fill=SESSION[si])
                if k >= 1: d.text((lane_x + 230, ty + 2), why(O_EVS, i, O_MARKS), font=F(R, 20), fill=TEXT)
                filled[si] += 1
        if t > 0.9: verdict(d, 80, 970, 1760, orders_three)
        yield img

@scene("free", "Ids are freed when their session ends. Once an order has been answered, its id may be minted again, and "
       "it names a new session: this log conforms, as two sessions. But minting the same id while its first session is "
       "still open is a problem, and Lean F M names the event.")
def _(p):
    img, d = base("4 · IDS ARE FREED", "Unique among open sessions, reusable after", "orders_reuse.json · orders_remint.json")
    for col, (q, title) in enumerate([(orders_reuse, "o7, answered, then minted again"), (orders_remint, "o7 minted again while still open")]):
        x = 80 + col * 900; evs = q["arguments"]["events"]
        d.text((x, 240), title, font=F(B, 30), fill=TEXT)
        sess = session_of(q) if q["result"].get("derivedSessions") else {}
        for i, e in enumerate(evs):
            si = sess.get(i, (None,))[0]
            row(d, x, 300 + i * 54, 860, i, e, SESSION[si] if si is not None else None)
        y = 300 + len(evs) * 54 + 20
        good = q["result"]["verdict"] == "conforms"
        msg = q["text"] if good else q["result"]["issues"][0]
        d.rounded_rectangle([x, y, x + 860, y + 150], radius=12, fill=CARD, outline=GREEN if good else RED, width=3)
        wrap(d, x + 20, y + 16, msg, F(R, 24), 820, GREEN if good else RED)
    img.save(p)

T_EVS = orders_served["arguments"]["events"]; T_STREAM = orders_served["result"]["events"]; T_SESS = session_of(orders_served)
THREAD_COLOURS = [(244, 114, 182), (34, 211, 238), (251, 146, 60), (226, 232, 240)]
@scene("threads", "Sessions are one way to cut a log. Threads are the other. A thread is one actor's own order of events: "
       "each event names the previous event its sender sent, its prev. Here one server thread, Api slash a 1, serves both "
       "orders in turn, so its prev chain runs through both sessions. Prev orders each actor's work, and with causes it "
       "says what happened before what. It never joins sessions: Lean F M still finds two orders, and both conform. "
       "A thread runs through many sessions, and a session through many threads.")
def _(p):
    img, d = base("5 · THREADS", "prev: each actor's own order", "orders_served.json · thread names from session_conform's stream")
    threads = []
    for ev in T_STREAM:
        if ev["thread"] not in threads: threads.append(ev["thread"])
    col = {t: THREAD_COLOURS[k % len(THREAD_COLOURS)] for k, t in enumerate(threads)}
    pos = {e["id"]: i for i, e in enumerate(T_EVS)}
    y0, rh = 300, 66
    d.text((150, 250), "event", font=F(B, 24), fill=MUTED); d.text((1000, 250), "thread (sender)", font=F(B, 24), fill=MUTED)
    d.text((1300, 250), "session", font=F(B, 24), fill=MUTED)
    # prev links, in the sender's thread colour, in the gutter
    for i, e in enumerate(T_EVS):
        if e.get("prev") in pos:
            j = pos[e["prev"]]; c = col[T_STREAM[i]["thread"]]
            x = 120 - 14 * threads.index(T_STREAM[i]["thread"])
            ya, yb = y0 + j * rh + 22, y0 + i * rh + 22
            d.line([(140, ya), (x, ya), (x, yb), (140, yb)], fill=c, width=3)
            d.polygon([(140, yb), (130, yb - 6), (130, yb + 6)], fill=c)
    for i, (e, ev) in enumerate(zip(T_EVS, T_STREAM)):
        c = col[ev["thread"]]; y = y0 + i * rh
        d.rounded_rectangle([150, y, 1840, y + 48], radius=8, fill=CARD, outline=c, width=2)
        d.rectangle([150, y + 4, 158, y + 44], fill=c)
        d.text((175, y + 10), f"{e['id']:<3} {e['label']}", font=F(B, 24), fill=c)
        d.text((480, y + 12), f"{e['from']} → {e['to']}" + (f"   prev {e['prev']}" if e.get("prev") else ""), font=F(M, 21), fill=TEXT)
        d.text((1000, y + 10), ev["thread"], font=F(B, 24), fill=c)
        d.text((1300, y + 12), T_SESS[i][1], font=F(M, 21), fill=SESSION[T_SESS[i][0]])
    d.rounded_rectangle([150, 850, 1840, 914], radius=12, fill=CARD, outline=GREEN, width=3)
    d.text((170, 866), orders_served["text"], font=F(B, 24), fill=GREEN)
    d.text((150, 940), "prev links drawn in the gutter: Api/a1's chain runs k1 → k2 → r2 → r1, through both orders",
           font=F(R, 24), fill=MUTED)
    img.save(p)

@scene("nested", "Protocols nest. A site logs you in, and the login mints a session id in a header. Each order task is "
       "its own protocol, given that id as its token. The include says how it passes in: with token equals sid. "
       "The diagram's box says so too. Leave the binding out, and the check refuses the text, naming the include.")
def _(p):
    img, d = base("6 · NESTED TASKS", "given and with: how a task gets its parent's id", "session_check site_check.json, site_unbound.json")
    text = SITE.splitlines(); lines = text[next(i for i, l in enumerate(text) if l.startswith("protocol")):]
    code(d, 80, 240, 960, 640, "Site: a login, then order tasks", [("!" if ("given" in l or "with" in l) else "") + l for l in lines], 21)
    paste_fit(img, os.path.join(WORK, "site.png"), (1070, 240, 1840, 1010))
    d.rounded_rectangle([80, 900, 1040, 1010], radius=12, fill=CARD, outline=RED, width=3)
    wrap(d, 100, 912, site_unbound["text"].replace("session_check rejected: ", "without the binding: "), F(R, 22), 920, RED, 6)
    img.save(p)

S_EVS = site_two["arguments"]["events"]; S_SESS = session_of(site_two)
@scene("logins", "Two logins, each running an order, interleaved. The token on every order message is a Link to the "
       "login that minted it, through the include's binding. So each order is a child session of its login, never "
       "merged into it: four sessions, each replayed against its own protocol, and all of them conform. "
       "And an order message carrying another login's token would give that order two parents. "
       "That is reported, naming both sessions.")
def _(p):
    img, d = base("7 · CHILD SESSIONS", "Each order is a child of the login that ran it", "site_two.json · site_cross.json · selfhost.session.identity.children")
    for i, e in enumerate(S_EVS):
        si = S_SESS[i][0]
        row(d, 80, 236 + i * 48, 1100, i, e, SESSION[si])
    for si, s in enumerate(site_two["result"]["derivedSessions"]["sessions"]):
        y = 240 + si * 46
        d.text((1220, y), f"{s['key']}", font=F(B, 26), fill=SESSION[si])
        if s.get("parent"): d.text((1500, y + 2), f"child of {s['parent']}", font=F(R, 22), fill=TEXT)
    d.rounded_rectangle([1220, 430, 1840, 520], radius=12, fill=CARD, outline=GREEN, width=3)
    wrap(d, 1240, 442, site_two["text"], F(B, 24), 580, GREEN, 6)
    issue = [x for x in site_cross["result"]["issues"] if "parent" in x][0]
    d.rounded_rectangle([1220, 540, 1840, 860], radius=12, fill=CARD, outline=RED, width=3)
    d.text((1240, 554), "another login's token:", font=F(B, 26), fill=RED)
    wrap(d, 1240, 600, issue, F(R, 23), 580, TEXT)
    img.save(p)

@scene("ambiguous", "And when the text does not say, Lean F M says so. In this lending protocol, copies run at once, and "
       "Return names no cause and carries no id. With logs that name their sessions that is fine. Without them, the "
       "copies cannot be told apart. The check stays okay, and an identity note says exactly what to add.")
def _(p):
    img, d = base("8 · WHEN THE TEXT IS AMBIGUOUS", "The ambiguity is resolved in the protocol text, or reported", "session_check lend_check.json · identity")
    code(d, 80, 240, 1760, 200, "Lend", ["protocol Lend (M, D) { sessions {", "  b: Borrow from M to D; Lent from D to M cause b; !Return from M to D; } }".replace("!", "")], 24)
    verdict(d, 80, 470, 1760, lend)
    d.rounded_rectangle([80, 560, 1840, 820], radius=12, fill=CARD, outline=AMBER, width=3)
    d.text((100, 576), "identity note", font=F(B, 28), fill=AMBER)
    wrap(d, 100, 624, lend["result"]["identity"][0], F(R, 28), 1720, TEXT)
    img.save(p)

OUTRO = "Sessions are fresh, or linked. The protocol text says which. Lean F M follows them through the log."
@scene("outro", OUTRO)
def _(p):
    img, d = base("LEANFM · SESSIONS", None)
    d.text((80, 340), "Fresh, or linked.", font=F(B, 96), fill=TEXT)
    d.text((80, 470), "The protocol text says which. LeanFM follows them through the log.", font=F(R, 40), fill=AMBER)
    d.text((80, 600), "selfhost.session.identity.marks · .checks · .scopes   (implemented)", font=F(M, 30), fill=GREEN)
    d.text((80, 650), "selfhost.session.identity.children                    (implemented)", font=F(M, 30), fill=GREEN)
    d.text((80, 700), "selfhost.session.identity.graph · .recursion          (next)", font=F(M, 30), fill=MUTED)
    img.save(p)

# ── narration, pictures, then one music bed under everything ──
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

# the score: enough cycles of synth.mq to cover the video, rendered by the Zig implementation
cycle = 27.5
cycles = int(total / cycle) + 1
# the mic's sympathetic strings turned down from 0.9999 to 0.9995; the project's synth.mq is unchanged
SYM_FROM, SYM_TO = "sym mic decay 0.9999", "sym mic decay 0.9995"
mq = open(os.path.join(MAQAM, SCORE)).read()
assert SYM_FROM in mq, "synth.mq no longer has the sympathetic decay this video turns down"
score_mq = os.path.join(WORK, "score.mq"); open(score_mq, "w").write(mq.replace(SYM_FROM, SYM_TO))
score = os.path.join(WORK, "score.wav")
run([f"{MAQAM}/zig-out/bin/maqam-live", "--render", score_mq, "--cycles", str(cycles), "--rate", "48000", "--wav", score], cwd=MAQAM)

video = os.path.join(WORK, "video.mp4")
with open(os.path.join(WORK, "parts.txt"), "w") as f:
    for p in parts: f.write(f"file '{p}'\n")
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(WORK, "parts.txt"),
     "-c", "copy", video])

inputs = ["-i", video, "-i", score]
voices = []
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
print(f"wrote {OUT} ({total:.1f}s, score {cycles} cycles of {SCORE})")
