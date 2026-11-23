"""Two real GoServer games, the traffic they made, and the CTL behind it: narrated and scored. The boards
are screenshots of the running app (build/frames, from play.py); the traffic, sessions, findings and
formulas are read from data/ (fetch.py and reports/ctl-translation). Usage: produce.py [out.mp4]"""
import json, os, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data"); FRAMES = os.path.join(D, "build/frames")
WORK = os.path.join(D, "build"); os.makedirs(WORK, exist_ok=True)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "leanfm-goserver-live.mp4")
PIPER = f"{ROOT}/video/.conda/bin/piper"; VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
SCORE_DIR = f"{ROOT}/projects/Maqam/impl/zig/source"; SCORE = "synth.mq"
FPS, W, H = 30, 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184); RED = (248, 113, 113)
BLUE = (125, 175, 255); VIOLET = (196, 160, 255); PINK = (244, 114, 182); CYAN = (34, 211, 238); ORANGE = (251, 146, 60); LIME = (163, 230, 53)
PEOPLE = {"ana": GREEN, "ben": BLUE, "cy": VIOLET, "dee": PINK, "eve": CYAN, "finn": ORANGE, "gus": LIME}
RULE = {"start": CYAN, "succession": GREEN, "order": ORANGE, "cause": AMBER, "choice": VIOLET, "possible": PINK, "end": TEXT}
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"; R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"; M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_f = {}
def F(p, s):
    if (p, s) not in _f: _f[p, s] = ImageFont.truetype(p, s)
    return _f[p, s]
def run(cmd, **kw): subprocess.run(cmd, check=True, **kw)
def load(n): return json.load(open(os.path.join(DATA, n + ".json")))

traffic = load("traffic"); log = load("log"); after = load("conform"); before = load("conform_before"); ctl = load("ctl_goserver")
games = traffic["games"]
frames = {k: sorted(os.listdir(os.path.join(FRAMES, k))) for k in games}

def base(tag, title=None, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN); d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    if title: d.text((80, 112), title, font=F(B, 50), fill=TEXT)
    if sub: d.text((80, 182), sub, font=F(R, 28), fill=AMBER)
    return img, d

def wrap(d, x, y, text, font, width, fill, gap=8):
    line = ""
    for wd in text.split():
        t = (line + " " + wd).strip()
        if d.textlength(t, font=font) > width and line: d.text((x, y), line, font=font, fill=fill); y += font.size + gap; line = wd
        else: line = t
    if line: d.text((x, y), line, font=font, fill=fill); y += font.size + gap
    return y

def box(d, x, y, w, h, color, title, body, size=26):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=color, width=3)
    d.text((x + 22, y + 16), title, font=F(B, 30), fill=color)
    return wrap(d, x + 22, y + 64, body, F(R, size), w - 44, TEXT)

scenes = []
def scene(id, text, animated=False, min_secs=0):
    def deco(fn): scenes.append((id, text, fn, animated, min_secs)); return fn
    return deco

@scene("title", "Two games of Go are running on one server. Four people on an eleven by eleven board, three people on a nine by nine. "
       "Every one of them is a real browser, talking to the real Go server. Let's watch it, record what it says on the wire, "
       "and ask Lean F M what it all means.")
def _(p):
    img, d = base("LEANFM · GOSERVER, LIVE")
    d.text((80, 300), "Two games, seven people, one server", font=F(B, 80), fill=TEXT)
    d.text((80, 420), "Real browsers, real traffic. LeanFM untangles it, and proves what the protocol promises.", font=F(R, 36), fill=AMBER)
    y = 540
    for k, g in games.items():
        d.text((120, y), g["title"], font=F(B, 36), fill=TEXT); d.text((560, y), f"{g['board']}×{g['board']}", font=F(R, 34), fill=MUTED)
        x = 760
        for nm in g["people"]:
            d.text((x, y), nm, font=F(B, 34), fill=PEOPLE[nm]); x += d.textlength(nm, font=F(B, 34)) + 40
        y += 80
    d.text((80, 960), "screenshots of the running app (play.py); traffic recorded from each browser; answers from LeanFM (video/goserver/data)", font=F(R, 24), fill=MUTED)
    img.save(p)

@scene("games", "Here they are, playing. Every stone is a click in one person's browser, sent to the server as a play move request. "
       "On the left, four colors fight over the eleven by eleven. On the right, three over the nine by nine. Both games at once, "
       "through the same server.", animated=True)
def games_anim(n):
    imgs = {k: [os.path.join(FRAMES, k, f) for f in frames[k]] for k in games}
    cache = {}
    def get(path):
        if path not in cache: cache[path] = Image.open(path).convert("RGB").resize((800, 800), Image.LANCZOS)
        return cache[path]
    for f in range(n):
        t = min(1.0, f / max(1, n * 0.9))
        img, d = base("1 · PLAYING", "Both games at once", "the running GoServer app, captured after every move")
        for col, k in enumerate(games):
            i = min(len(imgs[k]) - 1, int(t * (len(imgs[k]) - 1)))
            x = 120 + col * 880
            img.paste(get(imgs[k][i]), (x, 250))
            g = games[k]
            d.text((x, 215), f"{g['title']}  ·  move {i} of {len(imgs[k]) - 1}", font=F(B, 26), fill=TEXT)
            xx = x + 520
            for nm in g["people"]:
                d.text((xx, 1060 - 30), "", font=F(R, 10))
        yield img

EVS = log["log"]
@scene("traffic", "This is what the server actually saw: seven browsers, interleaved. Requests and answers from everyone, in one stream. "
       "This is the flat diagram: the union of every actor and every message. Each color is one person's browser.", animated=True)
def traffic_anim(n):
    rows = 22; total = len(EVS)
    for f in range(n):
        t = f / max(1, n - 1)
        top = int(t * max(0, total - rows))
        img, d = base("2 · ON THE WIRE", f"{sum(len(v) for v in traffic['traffic'].values())} API calls from 7 browsers", "data/log.json: the first 200 events, session tokens replaced by s1, s2, …")
        for r in range(rows):
            i = top + r
            if i >= total: break
            e = EVS[i]; person = (e["from"] if e["from"].startswith("Person") else e["to"]).split("/")[1]
            c = PEOPLE[person]; y = 240 + r * 37
            req = e["from"].startswith("Person")
            d.rectangle([80, y + 4, 88, y + 30], fill=c)
            d.text((104, y + 4), f"{i + 1:>3}", font=F(M, 20), fill=MUTED)
            d.text((170, y + 4), ("→ " if req else "← ") + e["label"], font=F(B, 21), fill=c if req else TEXT)
            d.text((520, y + 5), f"{e['from']} → {e['to']}", font=F(M, 19), fill=MUTED)
            fs = "  ".join(f"{k}={v}" for k, v in e["fields"].items() if k != "requestId")
            d.text((1000, y + 5), (f"cause {e['cause']}  " if e.get("cause") else "") + fs, font=F(M, 19), fill=TEXT)
        yield img

@scene("findings", "First contact between the specification and real traffic found three things. The server names the minted session "
       "with a different field than the spec. Two polled routes are not in the session type at all. And seven of fifty eight sessions "
       "broke the protocol: every browser asks for the game list while its previous request is still unanswered. "
       "The browser polls. The protocol said one request at a time. So the protocol was wrong, and now it says so.")
def _(p):
    img, d = base("3 · FIRST CONTACT", "What the real traffic showed", "data/log.json findings · data/conform_before.json")
    fi = log["findings"]; keys = list(fi)
    box(d, 80, 250, 860, 250, AMBER, "a field name", f"The sign-in answer names the minted session 'session' on the wire; the spec's SessionIssued says sessionId. ({fi[keys[0]]} sign-ins)", 25)
    sk = fi[keys[1]]
    box(d, 980, 250, 860, 250, AMBER, "routes outside the session type", "  ".join(f"{k}: {v} calls" for k, v in sk.items()) + ". Served and polled, never in the protocol.", 25)
    box(d, 80, 540, 1760, 230, RED, "before: " + before["reading"].split(";")[0], before["issues"][0][:200], 25)
    box(d, 80, 800, 1760, 200, GREEN, "after: listing games is its own session, beside the lobby", after["reading"], 26)
    img.save(p)

SESS = after["derivedSessions"]["sessions"]
persons = [s for s in SESS if not s.get("parent")]
gamesS = [s for s in SESS if s.get("parent") and "parents" not in s and any(s["key"] == x.get("parents", [None, None])[1] for x in SESS)]
joins = [s for s in SESS if "parents" in s]
@scene("untangled", "Now Lean F M untangles the stream, with no session ids in the log at all. Seven person sessions, one per browser. "
       "Two game sessions, each a child of the person who created it. And every seat, move and game state request is a join: "
       "it belongs to its person and to its game at once. Two hundred events, all following the protocol.")
def _(p):
    img, d = base("4 · UNTANGLED", "Seven people, two games, and the joins between them", "derivedSessions from session_conform · data/conform.json")
    d.text((80, 240), f"{len(persons)} person sessions", font=F(B, 34), fill=TEXT)
    y = 290
    for s in persons:
        d.text((110, y), f"{s['key']}: {s['count']} events", font=F(R, 26), fill=MUTED); y += 40
    d.text((700, 240), f"{len(gamesS)} game sessions", font=F(B, 34), fill=TEXT)
    y = 290
    for s in gamesS:
        d.text((730, y), f"{s['key']}, child of {s['parent']}", font=F(R, 26), fill=MUTED); y += 40
    d.text((700, 420), f"{len(joins)} joins (person and game)", font=F(B, 34), fill=TEXT)
    y = 470
    for s in joins[:9]:
        d.text((730, y), f"{s['key']}: {' + '.join(s['parents'])}", font=F(M, 22), fill=MUTED); y += 36
    if len(joins) > 9: d.text((730, y), f"… and {len(joins) - 9} more", font=F(R, 22), fill=MUTED)
    d.rounded_rectangle([80, 900, 1840, 970], radius=12, fill=CARD, outline=GREEN, width=3)
    d.text((100, 918), "session_conform conforms: " + after["reading"], font=F(B, 26), fill=GREEN)
    img.save(p)

CTL = ctl["formulas"]
DG = load("diagrams")
import re
HEX = {k: "#%02x%02x%02x" % v for k, v in RULE.items()}
def atoms(f):
    if isinstance(f, dict):
        out = []
        for k, v in f.items():
            if k == "after": out.append(v)
            else: out += atoms(v)
        return out
    if isinstance(f, list): return [a for x in f for a in atoms(x)]
    return []
def proto_of(fm):
    labs = atoms(fm["formula"])
    return DG["defines"].get(labs[0], "GoServer") if labs else "GoServer"
# the formulas grouped by the protocol their messages come from, in the order GoServer runs them
ORDERED = sorted(CTL, key=lambda fm: (DG["protocols"].index(proto_of(fm)) if proto_of(fm) in DG["protocols"] else 0))
_dcache = {}
def diagram(proto, labels, color):
    """The protocol's generated diagram with the formula's messages (label and arrow) in its color,
    rasterized to 820 px wide and cropped around them when the drawing is tall."""
    key = (proto, tuple(sorted(labels)), color)
    if key in _dcache: return _dcache[key]
    svg = DG["svg"][proto]; ys = []
    def hit(m):
        txt = m.group(2)
        if any(re.search(rf"(^|[\s:]){re.escape(l)}(\s|$)", txt) for l in labels) and not txt.startswith("["):
            y = re.search(r'y="([\d.]+)"', m.group(1)); ys.append(float(y.group(1)) if y else 0)
            attrs = re.sub(r'fill="[^"]*"', f'fill="{color}"', m.group(1)).replace('font-size="12"', 'font-size="14" font-weight="bold"')
            return f"<text{attrs}>{txt}</text>"
        return m.group(0)
    svg = re.sub(r"<text([^>]*)>([^<]*)</text>", hit, svg)
    def line(m):
        y1 = re.search(r'y1="([\d.]+)"', m.group(0)); y2 = re.search(r'y2="([\d.]+)"', m.group(0))
        if y1 and y2 and y1.group(1) == y2.group(1) and any(0 < float(y1.group(1)) - y <= 14 for y in ys):
            return re.sub(r'stroke="[^"]*"', f'stroke="{color}"', m.group(0)).replace('stroke-width="2.5"', 'stroke-width="5"')
        return m.group(0)
    svg = re.sub(r"<line[^>]*/>", line, svg)
    path = os.path.join(WORK, "diag.svg"); open(path, "w").write(svg)
    png = os.path.join(WORK, "diag.png")
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-width", "820", "-i", path, png])
    im = Image.open(png).convert("RGB")
    scale = 820 / float(re.search(r'width="([\d.]+)"', DG["svg"][proto]).group(1))
    if im.height > 760:
        cy = int((min(ys) if ys else 0) * scale)
        top = max(0, min(im.height - 760, cy - 300))
        im = im.crop((0, top, 820, top + 760))
    _dcache[key] = im
    return im

@scene("ctl", "And here is the protocol itself, turned into C T L. Every formula comes from the structure of GoServer's session type, "
       "and every one is decided by the model checker over its state graph of almost eleven thousand states. On the right, the "
       "diagram each formula comes from, its messages in the formula's color: signing in, the lobby, the game list, the game and its "
       "challenge, the bot's turn, seats, moves, merges and the game state. Seventy eight formulas. Seventy eight proved. "
       "This is exactly what the diagrams promise.", animated=True, min_secs=36)
def ctl_anim(n):
    rows = 17; total = len(ORDERED); reading = 6
    for f in range(n):
        t = min(1.0, f / max(1, n * 0.94))
        cur = min(total - 1, int(t * total))
        top = max(0, min(total - rows, cur - reading))
        img, d = base("5 · THE PROTOCOL AS CTL", "GoServer, every formula decided", f"reports/ctl-translation/translate_full.py · {total} formulas · {ctl['seconds']:.0f} s")
        for r in range(rows):
            i = top + r
            if i >= total: break
            fm = ORDERED[i]; y = 240 + r * 46
            if i == cur:
                d.rounded_rectangle([72, y - 6, 980, y + 34], radius=8, fill=CARD, outline=RULE[fm["rule"]], width=2)
            ok = fm["verdict"] == "proved"
            d.text((84, y), "✓" if ok else "✗", font=F(B, 24), fill=GREEN if ok else RED)
            d.text((118, y + 3), fm["rule"], font=F(B, 18), fill=RULE[fm["rule"]])
            c = fm["ctl"]
            d.text((250, y + 3), c if len(c) <= 52 else c[:51] + "…", font=F(M, 19), fill=TEXT if i == cur else MUTED)
        fm = ORDERED[cur]; proto = proto_of(fm)
        d.text((1010, 236), proto, font=F(B, 30), fill=RULE[fm["rule"]])
        d.text((1010, 276), "highlighted: " + ", ".join(dict.fromkeys(atoms(fm["formula"]))) if atoms(fm["formula"]) else "the whole session", font=F(R, 20), fill=MUTED)
        im = diagram(proto, set(atoms(fm["formula"])), HEX[fm["rule"]])
        s = min(830 / im.width, 700 / im.height)
        im2 = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
        img.paste(im2, (1010 + (830 - im2.width) // 2, 312))
        proved = sum(1 for x in CTL if x["verdict"] == "proved")
        d.rounded_rectangle([1380, 1020, 1840, 1066], radius=10, fill=CARD, outline=GREEN, width=2)
        d.text((1400, 1027), f"{proved} of {total} proved", font=F(B, 26), fill=GREEN)
        yield img

OUTRO = "Real games, real traffic, untangled by the protocol and proved in C T L. That is what the diagrams mean."
@scene("outro", OUTRO)
def _(p):
    img, d = base("LEANFM · GOSERVER, LIVE")
    d.text((80, 340), "That is what the diagrams mean.", font=F(B, 84), fill=TEXT)
    d.text((80, 470), "Real games, real traffic, untangled by the protocol and proved in CTL.", font=F(R, 40), fill=AMBER)
    img.save(p)

def tts(text, path):
    run([PIPER, "--model", VOICE, "--output_file", path], input=text.encode(), stderr=subprocess.DEVNULL)
    with wave.open(path) as w: return w.getnframes() / w.getframerate()

LEAD, TAIL, MUSIC_TAIL = 0.8, 1.4, 12.0
parts, voice_at, t = [], [], 0.0
for id, text, fn, animated, min_secs in scenes:
    wav = os.path.join(WORK, f"{id}.wav"); mp4 = os.path.join(WORK, f"{id}.mp4")
    secs = max(min_secs, LEAD + tts(text, wav) + TAIL + (MUSIC_TAIL if id == "outro" else 0))
    fade = f"fade=t=in:st=0:d=0.4,fade=t=out:st={secs - 0.4:.3f}:d=0.4,format=yuv420p"
    if animated:
        n = int(secs * FPS)
        enc = subprocess.Popen(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                                "-r", str(FPS), "-i", "-", "-vf", fade, "-c:v", "libx264", "-preset", "medium", "-crf", "18", mp4], stdin=subprocess.PIPE)
        for img in fn(n): enc.stdin.write(img.tobytes())
        enc.stdin.close()
        if enc.wait() != 0: sys.exit("encode failed")
    else:
        png = os.path.join(WORK, f"{id}.png"); fn(png)
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-t", f"{secs:.3f}", "-i", png,
             "-vf", fade if parts else fade.replace("fade=t=in:st=0:d=0.4,", ""), "-c:v", "libx264", "-preset", "medium", "-crf", "18", mp4])
    voice_at.append((wav, t + LEAD)); parts.append(mp4); t += secs
    print(f"{id}: {secs:.1f}s")
total = t

SYM_FROM, SYM_TO = "sym mic decay 0.9999", "sym mic decay 0.9995"
mq = open(os.path.join(SCORE_DIR, SCORE)).read(); assert SYM_FROM in mq
score_mq = os.path.join(WORK, "score.mq"); open(score_mq, "w").write(mq.replace(SYM_FROM, SYM_TO))
score = os.path.join(WORK, "score.wav")
run([f"{SCORE_DIR}/zig-out/bin/maqam-live", "--render", score_mq, "--cycles", str(int(total / 27.5) + 1), "--rate", "48000", "--wav", score], cwd=SCORE_DIR)
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
      f"afade=t=in:st=0:d=2,afade=t=out:st={total - 6:.3f}:d=6[music];[music][key]sidechaincompress=threshold=0.03:ratio=8:attack=20:release=600:makeup=1[bed];" \
      f"[bed][voice]amix=inputs=2:normalize=0,alimiter=limit=0.95[a]"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *inputs, "-filter_complex", mix, "-map", "0:v", "-map", "[a]",
     "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", "-t", f"{total:.3f}", OUT])
print(f"wrote {OUT} ({total:.1f}s)")
