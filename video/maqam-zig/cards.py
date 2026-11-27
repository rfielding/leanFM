"""Title cards for the maqam Zig video. Writes card_*.png next to this script."""
import os
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
W, H = 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184)
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
f = lambda p, s: ImageFont.truetype(p, s)

def base(tag):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([120, 90, W - 120, 95], fill=GREEN)
    d.text((120, 118), tag, font=f(M, 24), fill=GREEN)
    return img, d

def centered(d, y, s, font, fill):
    d.text(((W - d.textlength(s, font=font)) / 2, y), s, font=font, fill=fill)

def flowbox(d, x, y, w, h, head, lines, accent):
    d.rounded_rectangle([x, y, x + w, y + h], radius=18, fill=CARD, outline=accent, width=3)
    d.text((x + 32, y + 28), head, font=f(B, 34), fill=accent)
    yy = y + 92
    for l in lines:
        d.text((x + 32, yy), l, font=f(R, 25), fill=TEXT); yy += 40

def arrow(d, x0, x1, y):
    d.line([(x0, y), (x1 - 18, y)], fill=MUTED, width=5)
    d.polygon([(x1, y), (x1 - 26, y - 16), (x1 - 26, y + 16)], fill=MUTED)

# 1. the story
img, d = base("LEANFM  ·  ONE SPECIFICATION, TWO IMPLEMENTATIONS")
centered(d, 200, "A real-time Rust app, turned into a spec,", f(B, 64), TEXT)
centered(d, 285, "then ported to Zig and held to that spec", f(B, 64), AMBER)
bw, bh, gap, top = 470, 330, 95, 480
x0 = (W - (3 * bw + 2 * gap)) / 2
flowbox(d, x0, top, bw, bh, "1 · Rust", ["maqam-live: a just-intonation", "maqam sequencer and synth", "ALSA audio, NAM amp captures,", "terminal UI, LLM assistant"], MUTED)
arrow(d, x0 + bw + 12, x0 + bw + gap - 12, top + bh / 2)
flowbox(d, x0 + bw + gap, top, bw, bh, "2 · LeanFM spec", ["requirements, positive and", "negative, each with a test", "protocol MaqamLive: 8 actors", "the event log every build emits"], GREEN)
arrow(d, x0 + 2 * bw + gap + 12, x0 + 2 * (bw + gap) - 12, top + bh / 2)
flowbox(d, x0 + 2 * (bw + gap), top, bw, bh, "3 · Zig 0.17", ["ported with the spec as the", "contract; builds without Rust", "lock-free audio path:", "no allocation, no locks"], AMBER)
centered(d, 900, "Same commands, same messages, same session files.", f(R, 34), MUTED)
img.save(os.path.join(D, "card_1.png"))

# 2. the evidence
img, d = base("HOW WE KNOW IT IS THE SAME APP")
centered(d, 190, "Checked, not eyeballed", f(B, 68), TEXT)
rows = [
    ("209 / 210", "Zig tests pass  (1 timing test runs only in release builds)"),
    ("0 misses", "in 7,500 audio callbacks of 64 frames, with reverb and a NAM amp capture on"),
    ("~260 µs", "99th-percentile callback time, against a 1,333 µs deadline"),
    ("conforms", "the event log matches protocol MaqamLive  (LeanFM session_conform)"),
    ("identical", "offline render of default.mq gives the same samples on every run"),
    ("both pass", "make spec-check validates the Rust and the Zig against one requirements file"),
]
y = 330
for big, small in rows:
    d.rounded_rectangle([170, y, W - 170, y + 92], radius=14, fill=CARD, outline=EDGE, width=2)
    d.text((210, y + 20), big, font=f(B, 42), fill=GREEN)
    d.text((560, y + 30), small, font=f(R, 28), fill=TEXT)
    y += 110
img.save(os.path.join(D, "card_2.png"))

# 3. what you are about to see
img, d = base("THE DEMO")
centered(d, 300, "Build it.  Start it.  load default.mq", f(B, 76), TEXT)
centered(d, 430, "One full cycle of the session, 4 minutes 16 seconds.", f(R, 40), AMBER)
centered(d, 540, "Every frame is the real Zig TUI in a terminal. The sound is", f(R, 34), MUTED)
centered(d, 594, "recorded from maqam-live's own audio stream as it played.", f(R, 34), MUTED)
centered(d, 650, "No edits, no overdubs.", f(R, 34), MUTED)
img.save(os.path.join(D, "card_3.png"))

# 4. outro
img, d = base("LEANFM")
centered(d, 300, "That was the Zig build, live.", f(B, 76), TEXT)
centered(d, 430, "Specify the observable behaviour once.", f(R, 44), AMBER)
centered(d, 500, "Check every implementation against it.", f(R, 44), AMBER)
centered(d, 640, "projects/Maqam  ·  spec/Requirements.lean  ·  impl/zig/Implementation.lean", f(M, 28), MUTED)
img.save(os.path.join(D, "card_4.png"))
print("cards ok")
