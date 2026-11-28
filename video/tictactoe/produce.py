"""TicTacToe with LeanFM, from a prompt to a checked game: connect Claude Desktop, ask for TicTacToe and
see its source, then the diagrams LeanFM generates from it (the requirements list, the interaction
diagram, the simulated runs), the TypeScript implementation played and its log checked, and a video
asked for. The chat is re-enacted (drawn); every tool answer, screenshot and verdict is real
(capture.py). Writes tictactoe-walkthrough.mp4 and, for the book, book/generated/walk-chat-*.png.
Narration: local Piper voice. Usage: produce.py [out.mp4]   (ONLY=<scene> renders one scene's picture)"""
import json, os, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data"); WORK = os.path.join(D, "build"); os.makedirs(WORK, exist_ok=True)
BOOK = os.path.join(ROOT, "book", "generated")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "tictactoe-walkthrough.mp4")
PIPER = f"{ROOT}/video/.conda/bin/piper"; VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
FPS, W, H = 30, 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85); HEAD = (32, 40, 54)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184); BLUE = (125, 175, 255)
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"; R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_f = {}
def F(p, s):
    if (p, s) not in _f: _f[p, s] = ImageFont.truetype(p, s)
    return _f[p, s]
def run(cmd, **kw): subprocess.run(cmd, check=True, **kw)

WALK = json.load(open(os.path.join(DATA, "walk.json")))
PROTOCOL = open(os.path.join(ROOT, "examples/sessions/TicTacToe.leanfm")).read()
PROTO_LINES = PROTOCOL[PROTOCOL.index("protocol TicTacToe"):PROTOCOL.index("\nrequirements {")].splitlines()
CONFIG = ['{ "mcpServers": { "leanfm": {', '    "command": "~/code/leanFM/.lake/build/bin/leanfm-mcp",',
          '    "args": ["--stdio", "--forward", "http://127.0.0.1:8080/mcp"] } } }']

def wrap(d, x, y, text, font, width, fill, gap=8):
    line = ""
    for wd in text.split():
        t = (line + " " + wd).strip()
        if d.textlength(t, font=font) > width and line: d.text((x, y), line, font=font, fill=fill); y += font.size + gap; line = wd
        else: line = t
    if line: d.text((x, y), line, font=font, fill=fill); y += font.size + gap
    return y

def trim(path):
    """The screenshot without the empty panel space to its right and below."""
    im = Image.open(path).convert("RGB"); px = im.load(); bg = px[im.width - 3, im.height // 2]
    cols = [x for x in range(im.width) if any(abs(sum(px[x, y]) - sum(bg)) > 30 for y in range(0, im.height, 3))]
    return im.crop((0, 0, min(im.width, (max(cols) if cols else im.width) + 16), im.height))

def paste_fit(img, src, box, frame=True):
    bw, bh = box[2] - box[0], box[3] - box[1]; s = min(bw / src.width, bh / src.height, 1.6)
    im = src.resize((int(src.width * s), int(src.height * s)), Image.LANCZOS)
    x = box[0] + (bw - im.width) // 2; y = box[1] + (bh - im.height) // 2; img.paste(im, (x, y))
    if frame:
        d = ImageDraw.Draw(img)
        # a tool's output: the double gray rule the book uses for everything a tool drew
        d.rectangle([x - 4, y - 4, x + im.width + 3, y + im.height + 3], outline=(128, 128, 128), width=2)
        d.rectangle([x - 9, y - 9, x + im.width + 8, y + im.height + 8], outline=(128, 128, 128), width=2)

def code(d, x, y, w, h, head, lines, size=22):
    # a source: the single blue rule the book uses for what someone wrote
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=(40, 74, 160), width=3)
    d.text((x + 22, y + 14), head, font=F(B, 24), fill=BLUE)
    f = F(M, size); lh = int(size * 1.4); yy = y + 60
    for line in lines:
        if yy + lh > y + h: break
        d.text((x + 22, yy), line, font=f, fill=TEXT); yy += lh

def base(tag, title, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN); d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    d.text((80, 112), title, font=F(B, 50), fill=TEXT)
    if sub: d.text((80, 182), sub, font=F(R, 28), fill=AMBER)
    return img, d

def chat(p, turns):
    img = Image.new("RGB", (W, H), (26, 25, 24)); d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 300, H], fill=(20, 19, 18)); d.text((40, 40), "Claude Desktop", font=F(B, 28), fill=TEXT)
    d.text((40, 84), "leanfm · connected", font=F(R, 20), fill=GREEN)
    d.text((40, H - 60), "re-enacted chat; every tool answer is LeanFM's real one", font=F(R, 16), fill=MUTED)
    y = 50; x0, x1 = 380, W - 120
    for who, body in turns:
        if who == "user":
            f = F(R, 28); w = min(x1 - x0, int(d.textlength(body, font=f)) + 60)
            d.rounded_rectangle([x1 - w, y, x1, y + 66], radius=20, fill=(48, 46, 43)); d.text((x1 - w + 30, y + 17), body, font=f, fill=TEXT); y += 96
        elif who == "claude": y = wrap(d, x0, y, body, F(R, 27), x1 - x0, TEXT, 10) + 22
        elif who == "tool":
            name, verdict, detail = body
            d.rounded_rectangle([x0, y, x0 + 900, y + 56], radius=12, fill=(36, 35, 33), outline=EDGE, width=2)
            d.text((x0 + 22, y + 13), f"leanfm · {name}", font=F(M, 24), fill=BLUE)
            d.text((x0 + 880, y + 13), verdict, font=F(B, 24), fill=GREEN, anchor="ra"); y += 70
            if detail: y = wrap(d, x0 + 22, y, detail[:240], F(M, 21), x1 - x0 - 44, MUTED, 6) + 18
        elif who == "inline":
            # an MCP app drawn inline under its tool call, as the host shows it
            path, hh = body
            src = trim(path); s_ = min((x1 - x0 - 20) / src.width, hh / src.height, 1.6)
            im = src.resize((int(src.width * s_), int(src.height * s_)), Image.LANCZOS)
            d.rounded_rectangle([x0, y, x0 + im.width + 20, y + im.height + 44], radius=12, fill=(17, 17, 16), outline=EDGE, width=2)
            d.text((x0 + 14, y + 8), "LeanFM view · inline", font=F(R, 18), fill=MUTED)
            img.paste(im, (x0 + 10, y + 34)); y += im.height + 64
        elif who == "code":
            lines = body; h = 30 * len(lines) + 30
            d.rounded_rectangle([x0, y, x1, y + h], radius=12, fill=(17, 17, 16), outline=(40, 74, 160), width=3)
            for k, l in enumerate(lines): d.text((x0 + 24, y + 16 + 30 * k), l, font=F(M, 22), fill=TEXT)
            y += h + 22
    img.save(p)

scenes = []
def scene(id, text, book=None):
    def deco(fn): scenes.append((id, text, fn, book)); return fn
    return deco

intro = WALK["intro"]; st = intro["standing"]
@scene("title", "TicTacToe with LeanFM. From one prompt to a game whose every move is checked against its specification, "
       "with the diagrams drawn before any code exists.")
def _(p):
    img, d = base("a walkthrough", "TicTacToe with LeanFM", "from a prompt to a checked game")
    wrap(d, 80, 300, "1. Connect Claude Desktop to LeanFM.   2. Ask for TicTacToe and see its source.   3. The diagrams LeanFM "
         "generates from it, and the game played by simulation.   4. A small TypeScript implementation, its log checked.   "
         "5. Ask for a video, like this one.", F(R, 34), W - 160, TEXT, 18)
    img.save(p)

@scene("connect", "Connect once. Claude Desktop starts LeanFM's MCP relay, which talks to the server make serve runs. "
       "Then ask LeanFM to introduce itself: what it is, the rule for writing requirements, and what to call next.", "connect")
def _(p):
    chat(p, [("code", CONFIG), ("user", "Introduce LeanFM"),
             ("tool", ("introduction", "answered", intro["about"][:230] + "…")),
             ("claude", f"LeanFM checks requirements before code exists. Its own specification has {st.get('proved', 0)} proved "
                        f"requirements and {st.get('sorry', 0)} still in prose (sorry). Start with the requirements list of a protocol file.")])

@scene("prompt", "Ask for a TicTacToe game. Claude writes it as a protocol: X starts, the referee tells O, and the players take turns until "
       "the referee announces a result. Five rounds at most, so every game ends. This text is the source; everything after it is generated.", "prompt")
def _(p):
    chat(p, [("user", "Make a TicTacToe game"),
             ("claude", "Here it is as a protocol in examples/sessions/TicTacToe.leanfm, with five requirements under it."),
             ("code", PROTO_LINES[:22]),
             ("tool", ("session_check", WALK["check"]["verdict"], WALK["check"]["reading"]))])

@scene("inline", "In the chat, LeanFM's viewer comes up inline, right under the tool call: ask for TicTacToe's requirements and the "
       "requirements list appears in the conversation, ready to browse, each row with its standing.", "inline")
def _(p):
    chat(p, [("user", "Show me TicTacToe's requirements"),
             ("tool", ("session_explore", "outlined", "")),
             ("inline", (os.path.join(DATA, "tree.png"), 420)),
             ("claude", "Seven requirements, all proved. Pick a row to see its diagram and the CTL it reduces to.")])

@scene("banner", "And now, the important part. Everything from here on is generated by LeanFM from that protocol. "
       "Nothing is drawn by hand: the list of requirements, the diagram, and the game played by simulation.")
def _(p):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([140, 300, W - 140, H - 300], outline=(128, 128, 128), width=4)
    d.rectangle([152, 312, W - 152, H - 312], outline=(128, 128, 128), width=4)
    d.text((W // 2, H // 2 - 60), "Here come the generated diagrams", font=F(B, 64), fill=AMBER, anchor="mm")
    d.text((W // 2, H // 2 + 30), "drawn by LeanFM from the protocol · nothing by hand", font=F(R, 34), fill=TEXT, anchor="mm")
    img.save(p)

@scene("tree", "First the requirements list, in LeanFM's viewer. Every row is a named requirement with its standing: all seven proved, "
       "including two that LeanFM demands of every protocol. The CTL each one reduces to is folded under it.")
def _(p):
    img, d = base("generated · the requirements list", "TicTacToe's requirements", "session_explore, opened in LeanFM's viewer")
    paste_fit(img, trim(os.path.join(DATA, "tree.png")), (100, 260, W - 100, H - 60))
    img.save(p)

@scene("diagram", "The interaction diagram. The rounds are one loop, at most five, and each choice names the role that decides: here the referee, "
       "who either hands the turn over or announces the result.")
def _(p):
    img, d = base("generated · the interaction diagram", "TicTacToe as a sequence diagram", "the loop drawn once, at most five rounds")
    paste_fit(img, trim(os.path.join(DATA, "diagram.png")), (100, 240, W - 100, H - 40))
    img.save(p)

@scene("animate", "And play it. LeanFM's simulator generates games from the protocol alone and animates their events. "
       "No implementation exists yet: these are the runs the specification allows.")
def _(p):
    img, d = base("generated · simulated runs", "Played by simulation", "session_simulate: not a real run, every event allowed by the protocol")
    paste_fit(img, trim(os.path.join(DATA, "animate.png")), (100, 240, W - 100, H - 40))
    img.save(p)

ts_lines = WALK["typescript"].splitlines()
@scene("implement", f"Then the code, kept small: TicTacToe in about forty lines of TypeScript. The referee writes every protocol message to a log. "
       f"Here X won, in {len(WALK['events'])} events, and LeanFM checked the log against the protocol: it conforms.")
def _(p):
    img, d = base("source, then its run checked", "A small TypeScript implementation", f"{WALK['outcome']} · session_conform: {WALK['conform']['verdict']}")
    code(d, 80, 240, 760, H - 300, "book/examples/tictactoe.ts", ts_lines[24:], 16)
    paste_fit(img, Image.open(os.path.join(DATA, "game.png")).convert("RGB"), (880, 250, W - 60, 900))
    d.text((880, 940), "session_conform: " + WALK["conform"]["reading"], font=F(M, 24), fill=GREEN)
    img.save(p)

@scene("askvideo", "Finally, ask for a video. The same capture and narration produce this walkthrough from the specification, so a video "
       "can be the prompt for the code, before any code exists.", "video")
def _(p):
    chat(p, [("user", "Make a video of this walkthrough"),
             ("claude", "Running make video-tictactoe: it captures LeanFM's real answers and viewer, narrates each scene, and writes the video."),
             ("code", ["$ make video-tictactoe", f"game: {WALK['outcome']}, {len(WALK['events'])} events; conform: {WALK['conform']['verdict']}",
                       "wrote video/tictactoe/tictactoe-walkthrough.mp4"])])

def tts(text, path):
    run([PIPER, "--model", VOICE, "--length_scale", "1.08", "--output_file", path], input=text.encode(), stderr=subprocess.DEVNULL)
    with wave.open(path) as w: return w.getnframes() / w.getframerate()

LEAD, TAIL = 0.6, 1.0
only = os.environ.get("ONLY")
parts, voice_at, t = [], [], 0.0
for id, text, fn, book in scenes:
    png = os.path.join(WORK, f"{id}.png")
    if only:
        if id == only: fn(png)
        continue
    fn(png)
    if book: Image.open(png).save(os.path.join(BOOK, f"walk-chat-{book}.png"))
    wav = os.path.join(WORK, f"{id}.wav"); mp4 = os.path.join(WORK, f"{id}.mp4")
    secs = LEAD + tts(text, wav) + TAIL
    fade_in = "" if not parts else "fade=t=in:st=0:d=0.4,"
    fade = f"{fade_in}fade=t=out:st={secs - 0.4:.3f}:d=0.4,format=yuv420p"
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-t", f"{secs:.3f}",
         "-i", png, "-vf", fade, "-c:v", "libx264", "-preset", "medium", "-crf", "20", mp4])
    voice_at.append((wav, t + LEAD)); parts.append(mp4); t += secs
    print(f"{id}: {secs:.1f}s")
if only: sys.exit(0)
video = os.path.join(WORK, "video.mp4")
with open(os.path.join(WORK, "parts.txt"), "w") as f:
    for p in parts: f.write(f"file '{p}'\n")
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(WORK, "parts.txt"), "-c", "copy", video])
inputs = ["-i", video]; voices = []
for k, (wav, at) in enumerate(voice_at):
    inputs += ["-i", wav]; ms = int(at * 1000)
    voices.append(f"[{k + 1}:a]adelay={ms}|{ms},aformat=sample_rates=48000:channel_layouts=stereo[v{k}]")
mix = ";".join(voices) + ";" + "".join(f"[v{k}]" for k in range(len(voices))) + \
      f"amix=inputs={len(voices)}:normalize=0,apad,atrim=0:{t:.3f},alimiter=limit=0.95[a]"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *inputs, "-filter_complex", mix, "-map", "0:v", "-map", "[a]",
     "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", f"{t:.3f}", OUT])
print(f"wrote {OUT} ({t / 60:.1f} min)")
