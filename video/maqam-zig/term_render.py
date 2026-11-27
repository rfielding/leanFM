"""Replay capture.jsonl into a pyte terminal and render 1920x1080 RGB frames.
Usage: term_render.py <capdir> <cols> <rows> <fps> (--png t1,t2,... | --raw)  ; --raw writes rgb24 to stdout."""
import base64, json, sys, os
sys.path.insert(0, os.environ.get("PYTE_PATH", os.path.join(os.path.dirname(__file__), "..", "py")))
import pyte
from PIL import Image, ImageDraw, ImageFont

capdir, cols, rows, fps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
W, H = 1920, 1080
BG = (13, 17, 23)
FG = (220, 226, 234)
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
MONOB = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
SANSB = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
HEADER = 64
size = 28
font = ImageFont.truetype(MONO, size)
fontb = ImageFont.truetype(MONOB, size)
cw = font.getlength("M")
ch = 33
while cols * cw > W - 40 or rows * ch > H - HEADER - 20:
    size -= 1
    font = ImageFont.truetype(MONO, size); fontb = ImageFont.truetype(MONOB, size)
    cw = font.getlength("M"); ch = int(size * 1.18)
ox = int((W - cols * cw) / 2)
oy = HEADER + int((H - HEADER - rows * ch) / 2)

NAMED = {
    "black": (40, 44, 52), "red": (240, 98, 98), "green": (110, 214, 120), "brown": (229, 192, 90),
    "yellow": (229, 192, 90), "blue": (97, 165, 245), "magenta": (205, 120, 230), "cyan": (86, 210, 220),
    "white": (220, 226, 234), "brightblack": (110, 118, 130), "brightred": (255, 130, 130),
    "brightgreen": (150, 240, 160), "brightbrown": (255, 220, 120), "brightyellow": (255, 220, 120),
    "brightblue": (140, 190, 255), "brightmagenta": (230, 160, 250), "brightcyan": (130, 235, 240),
    "brightwhite": (255, 255, 255),
}

def color(c, default):
    if c == "default":
        return default
    if c in NAMED:
        return NAMED[c]
    if len(c) == 6:
        try:
            return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))
        except ValueError:
            pass
    return default

hfont = ImageFont.truetype(SANSB, 26)
hsmall = ImageFont.truetype(SANS, 22)

def header(draw):
    draw.rectangle([0, 0, W, HEADER], fill=(20, 26, 36))
    draw.rectangle([0, HEADER - 3, W, HEADER], fill=(52, 211, 153))
    draw.text((32, 17), "maqam-live", font=hfont, fill=(255, 255, 255))
    x = 32 + hfont.getlength("maqam-live") + 18
    draw.text((x, 20), "the Zig build, generated from the LeanFM specification of the Rust app",
              font=hsmall, fill=(148, 163, 184))
    tag = "LIVE · ALSA · 48 kHz"
    draw.text((W - 32 - hsmall.getlength(tag), 20), tag, font=hsmall, fill=(251, 191, 36))

def render(screen):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    header(d)
    for y in range(rows):
        line = screen.buffer[y]
        x = 0
        while x < cols:
            c = line[x]
            fg = color(c.fg, FG); bg = color(c.bg, BG)
            if c.bold and c.fg in NAMED and not c.fg.startswith("bright"):
                fg = NAMED.get("bright" + c.fg, fg)
            if c.reverse:
                fg, bg = bg, fg
            # extend run of same style
            run = [c.data]
            x2 = x + 1
            while x2 < cols:
                n = line[x2]
                if (n.fg, n.bg, n.bold, n.reverse) != (c.fg, c.bg, c.bold, c.reverse):
                    break
                run.append(n.data); x2 += 1
            px = ox + x * cw; py = oy + y * ch
            if bg != BG:
                d.rectangle([px, py, ox + x2 * cw - 1, py + ch - 1], fill=bg)
            f = fontb if c.bold else font
            for i, s in enumerate(run):
                if s and s != " ":
                    if "─" <= s[0] <= "╿":
                        box(d, s[0], ox + (x + i) * cw, py, fg)
                    else:
                        d.text((ox + (x + i) * cw, py + (ch - size) / 2 - 1), s, font=f, fill=fg)
            x = x2
    if not screen.cursor.hidden:
        cx, cy = screen.cursor.x, screen.cursor.y
        if cy < rows and cx < cols:
            d.rectangle([ox + cx * cw, oy + cy * ch, ox + (cx + 1) * cw - 1, oy + (cy + 1) * ch - 1], fill=(200, 210, 220))
    return img

def box(d, c, x, y, fg):
    """Box drawing that joins across cells (fonts leave gaps at this line height)."""
    mx = x + cw / 2; my = y + ch / 2; r = x + cw; b = y + ch
    L = {"─": "lr", "│": "ud", "┌": "rd", "┐": "ld", "└": "ru", "┘": "lu", "├": "udr", "┤": "udl",
         "┬": "lrd", "┴": "lru", "┼": "udlr", "╭": "rd", "╮": "ld", "╰": "ru", "╯": "lu",
         "═": "lr", "║": "ud", "╔": "rd", "╗": "ld", "╚": "ru", "╝": "lu", "╌": "lr", "┄": "lr"}.get(c)
    if L is None:
        d.text((x, y + (ch - size) / 2 - 1), c, font=font, fill=fg)
        return
    w = 2
    if "l" in L: d.line([(x, my), (mx, my)], fill=fg, width=w)
    if "r" in L: d.line([(mx, my), (r, my)], fill=fg, width=w)
    if "u" in L: d.line([(mx, y), (mx, my)], fill=fg, width=w)
    if "d" in L: d.line([(mx, my), (mx, b)], fill=fg, width=w)

def chunks():
    with open(os.path.join(capdir, "capture.jsonl")) as f:
        for line in f:
            e = json.loads(line)
            yield e["t"], base64.b64decode(e["b"])

screen = pyte.Screen(cols, rows)
stream = pyte.ByteStream(screen)

def frames(t_end):
    """Yield (frame_index, screen-dirty?) stepping fps through the capture."""
    it = chunks()
    pending = next(it, None)
    n = 0
    while n / fps <= t_end:
        t = n / fps
        changed = False
        while pending and pending[0] <= t:
            stream.feed(pending[1]); changed = True
            pending = next(it, None)
        yield n, changed
        n += 1

marks = json.load(open(os.path.join(capdir, "marks.json")))
if sys.argv[5] == "--png":
    want = [float(x) for x in sys.argv[6].split(",")]
    for n, _ in frames(max(want)):
        for w in want:
            if int(w * fps) == n:
                render(screen).save(os.path.join(capdir, f"shot_{w:.1f}.png"))
else:
    t_start = float(sys.argv[6]); t_end = float(sys.argv[7])
    out = sys.stdout.buffer
    last = None; key = None
    for n, changed in frames(t_end):
        if n / fps < t_start:
            continue
        k = (tuple(tuple((c.data, c.fg, c.bg, c.bold, c.reverse) for c in (screen.buffer[y][x] for x in range(cols))) for y in range(rows)),
             screen.cursor.x, screen.cursor.y, screen.cursor.hidden) if changed or last is None else key
        if k != key or last is None:
            last = render(screen).tobytes(); key = k
        out.write(last)
