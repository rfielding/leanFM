"""Narrated cut: goal, Rust -> LeanFM spec, the artifacts, Rust vs Zig code, then the live take.
Usage: produce.py <take dir> <out.mp4>   (PYTE_PATH must point at pyte for term_render.py)"""
import json, os, subprocess, sys, wave
import numpy as np
from PIL import Image, ImageDraw, ImageFont

D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))  # the project root, two levels up
PIPER = f"{ROOT}/video/.conda/bin/piper"
VOICE = f"{ROOT}/video/voices/en_US-lessac-medium.onnx"
take, out = sys.argv[1], sys.argv[2]
work = os.path.join(take, "narrated"); os.makedirs(work, exist_ok=True)
A = os.path.join(D, "assets")
FPS = 30
W, H = 1920, 1080
BG = (13, 17, 23); CARD = (24, 30, 41); EDGE = (51, 65, 85)
GREEN = (52, 211, 153); AMBER = (251, 191, 36); TEXT = (241, 245, 249); MUTED = (148, 163, 184)
RED = (248, 113, 113); BLUE = (125, 175, 255); RUSTC = (222, 140, 90); ZIGC = (247, 164, 29)
B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
M = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
F = lambda p, s: ImageFont.truetype(p, s)

def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)

# ── slide primitives ──
def base(tag, title=None, sub=None):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    d.rectangle([80, 50, W - 80, 54], fill=GREEN)
    d.text((80, 70), tag, font=F(M, 24), fill=GREEN)
    if title: d.text((80, 112), title, font=F(B, 50), fill=TEXT)
    if sub: d.text((80, 182), sub, font=F(R, 28), fill=AMBER)
    return img, d

KW = {"let", "if", "else", "const", "var", "fn", "pub", "while", "return", "orelse", "match", "struct",
      "protocol", "choice", "or", "from", "to", "cause", "sessions", "continue", "rec", "def", "mut",
      "try", "for", "and", "null", "Some", "Ok"}

def code(d, x, y, w, h, head, color, lines, size=24):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=CARD, outline=EDGE, width=2)
    d.rounded_rectangle([x, y, x + w, y + 52], radius=14, fill=(32, 40, 54))
    d.rectangle([x, y + 38, x + w, y + 52], fill=(32, 40, 54))
    d.text((x + 22, y + 12), head, font=F(B, 24), fill=color)
    f = F(M, size); lh = int(size * 1.42); yy = y + 70
    for line in lines:
        hl = line.startswith("!")
        if hl:
            line = line[1:]
            d.rectangle([x + 4, yy - 3, x + w - 4, yy + lh - 5], fill=(60, 30, 34) if color == RUSTC else (22, 58, 46))
        cx = x + 22
        comment = line.find("//") if "//" in line else line.find("--") if line.lstrip().startswith("--") else -1
        body, tail = (line[:comment], line[comment:]) if comment >= 0 else (line, "")
        tok = ""
        for chh in body + " ":
            if chh.isalnum() or chh == "_":
                tok += chh; continue
            if tok:
                d.text((cx, yy), tok, font=f, fill=BLUE if tok in KW else TEXT); cx += f.getlength(tok); tok = ""
            if chh != " " or True:
                d.text((cx, yy), chh, font=f, fill=TEXT); cx += f.getlength(chh)
        if tail:
            d.text((cx - f.getlength(" "), yy), tail, font=f, fill=MUTED)
        yy += lh

def paste_fit(img, path, box, crop=None):
    im = Image.open(path).convert("RGB")
    if crop: im = im.crop(crop)
    bw, bh = box[2] - box[0], box[3] - box[1]
    s = min(bw / im.width, bh / im.height)
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    x = box[0] + (bw - im.width) // 2; y = box[1] + (bh - im.height) // 2
    img.paste(im, (x, y))
    ImageDraw.Draw(img).rectangle([x - 1, y - 1, x + im.width, y + im.height], outline=EDGE, width=2)

def bullets(d, x, y, items, size=30, gap=58, color=TEXT):
    for it in items:
        d.text((x, y), "•", font=F(B, size), fill=GREEN)
        d.text((x + 34, y), it, font=F(R, size), fill=color); y += gap

# ── the scenes: (id, narration, draw function) ──
scenes = []
def scene(id, text):
    def deco(fn):
        scenes.append((id, text, fn)); return fn
    return deco

@scene("goal", "This is an experiment in specification driven engineering. We took maqam live, a real time music "
       "app written in Rust, and used LeanFM to turn it into a specification: what the app does, what it must "
       "never do, and the protocol between its parts. Then we implemented the same app again, in Zig, against "
       "that specification. If the specification is good, the second implementation should be indistinguishable "
       "from the first. And that should be checked by machine, not taken on trust.")
def _(img_path):
    img = Image.open(os.path.join(D, "card_1.png")); img.save(img_path)

@scene("original", "Maqam live is a live coding sequencer for just intonation maqam. You type a phrase, like d bayati "
       "four four four four, and it plays in pure ratios, through filters, effects, sympathetic strings and neural "
       "amp models. It is about twenty thousand lines of Rust. Its audio callback runs every one point three "
       "milliseconds at sixty four frames, and it must never block.")
def _(p):
    img, d = base("1 · THE ORIGINAL", "maqam-live, the upstream Rust", "github.com/rfielding/maqam @ c80b35d")
    paste_fit(img, f"{ROOT}/projects/Maqam/book/screenshot1.png", (80, 250, 1100, 900))
    bullets(d, 1170, 280, ["~20,000 lines of Rust", "cpal audio, crossbeam channels", "nam-rs neural amp models",
                           "ratatui terminal UI", "LLM assistant, MP4 recorder", "1.333 ms deadline per callback"], 30, 70)
    d.text((80, 930), "the upstream TUI (book/screenshot1.png)", font=F(R, 24), fill=MUTED)
    img.save(p)

@scene("protocol", "LeanFM read the Rust source and wrote down its observable behaviour. First, the protocol: eight "
       "actors. The performer, the app, the audio callback, the recorder, f f m peg, the language model, the web, and the "
       "disk. Every interaction is a session type. A command is either shown, or rejected. A load either succeeds and "
       "resyncs the audio, or fails with a line number. LeanFM draws this diagram from the specification itself. "
       "Nobody drew it by hand.")
def _(p):
    img, d = base("2 · RUST → LEANFM SPEC", "The protocol: spec/Maqam.leanfm", "session types over 8 actors, checked by LeanFM")
    code(d, 80, 240, 900, 760, "spec/Maqam.leanfm", GREEN, [
        "protocol MaqamLive (Performer, App, Audio,",
        "    Recorder, Ffmpeg, Llm, Web, Disk) {",
        "  rec Live {",
        "    choice {",
        "!      c: Command from Performer to App;",
        "      choice {",
        "        sessions { Phrase from App to Audio;",
        "                   Position from Audio to App; }",
        "        Shown from App to Performer cause c;",
        "      } or {",
        "!        Rejected from App to Performer cause c;",
        "      }",
        "    } or {",
        "      s: Session from Performer to App;",
        "      w: ReadOrWrite from App to Disk cause s;",
        "      ...", ], 23)
    paste_fit(img, os.path.join(A, "arch.png"), (1020, 240, 1840, 1000), crop=(0, 0, 1650, 950))
    d.text((1020, 1010), "renders/maqam-live-dark.pdf, generated from the spec", font=F(R, 22), fill=MUTED)
    img.save(p)

@scene("requirements", "Second, the requirements. Each one is a positive invariant, or a negative one. Always: a rejected "
       "command changes nothing. Always: a jump row with N passes jumps back N minus one times, then falls through. "
       "Never: the audio callback blocks. Never: any input crashes the app. And every requirement must map to a "
       "control and a test, in every implementation.")
def _(p):
    img, d = base("2 · RUST → LEANFM SPEC", "The requirements: spec/Requirements.lean", "positive (always) and negative (never), each mapped to a control and a test")
    code(d, 80, 240, 1760, 770, "spec/Requirements.lean", GREEN, [
        "!{ name := \"A rejected command changes nothing\", mode := .never,",
        "   expression := \"Rejected and an AudioCmd for the same command line\" }",
        "!{ name := \"Jump passes\", mode := .always,",
        "   expression := \"j X N passes the jump row N times: N-1 JumpTaken then one",
        "                  JumpExhausted that resets its counter\" }",
        "!{ name := \"The audio callback never blocks\", mode := .never,",
        "   predicate := \"a blocking lock, channel send, file or network operation",
        "                 inside the output callback (try_recv and try_lock only)\" }",
        "!{ name := \"No input crashes the app\", mode := .never,",
        "   predicate := \"a command line, session line or scraped page that makes it panic\",",
        "   handlingPlan := \"Counterexample known in impl/rust: create X 1/1 then d x",
        "                    panics in build_phrase; impl/zig rejects it.\" }",
        "!{ name := \"Implementations stand alone\", mode := .never, ... }", ], 25)
    img.save(p)

@scene("artifacts", "These are not slides we made up. They are artifacts in the repository. The book is generated from the "
       "specification, and its known gaps chapter records where the Rust itself breaks the rules. For example: create "
       "a jins with only one note, play it, and the Rust binary panics. Here is the transcript. The requirement still "
       "forbids it, so the Zig had to reject that input with a message instead.")
def _(p):
    img, d = base("3 · THE ARTIFACTS", "The book, and the evidence it points to", "book/main-dark.pdf · reports/reverse-engineering/")
    paste_fit(img, os.path.join(A, "book_12.png"), (80, 240, 600, 1010))
    paste_fit(img, os.path.join(A, "book_16.png"), (630, 240, 1150, 1010))
    code(d, 1180, 240, 660, 360, "Rust: panic-one-note-jins.txt", RUSTC, [
        "> create Zz 1/1", "created jins Zz", "> d zz 4", "!thread 'main' panicked at", "!  core/src/cmp.rs:1031:9:",
        "!assertion failed: min <= max"], 22)
    code(d, 1180, 630, 660, 380, "Zig: same input", ZIGC, [
        "> create Zz 1/1", "created jins Zz", "> d zz 4", "!✗ a phrase needs at least 3", "!  notes in its scale, but",
        "!  this one has 1; give the", "!  jins more ratios ..."], 22)
    img.save(p)

@scene("mapping", "Each implementation has its own mapping file, which binds every actor and message of the specification "
       "to real code, with a reason for every proof obligation. LeanFM validates both mappings against the same "
       "requirements. And one comparison report measures every build the same way. The Zig passes its tests, renders "
       "deterministically, its event log conforms to the protocol, and its audio callback missed no deadline at "
       "sixty four frames.")
def _(p):
    img, d = base("3 · THE ARTIFACTS", "Mapping, validation, measurement", "impl/zig/Implementation.lean · reports/compare/summary.md")
    code(d, 80, 240, 1760, 380, "impl/zig/Implementation.lean", GREEN, [
        "{ actor := \"Audio\", typeName := \"audio.Engine.process ...\", sourceFile := \"impl/zig/source/src/audio.zig\"",
        "!, justifications := why \"proof:The audio callback never blocks\"",
        "    \"Everything is preallocated in Engine.create; process only calls Ring.tryRecv, publishes",
        "     through shared.Shared atomics (jump counters are a fixed atomic table, not a locked map)",
        "     and hands released objects back on the garbage ring ...\" }", ], 23)
    rows = [("implementation", "spec", "check", "render", "events", "bench @ 64 frames"),
            ("rust (upstream)", "validated", "pass", "not provided", "—", "not provided"),
            ("zig", "validated", "pass", "deterministic", "conforms", "0 misses · p99 268 µs")]
    xs = [110, 430, 640, 820, 1120, 1360]; y = 680
    d.rounded_rectangle([80, 650, 1840, 900], radius=14, fill=CARD, outline=EDGE, width=2)
    for i, r in enumerate(rows):
        for x, c in zip(xs, r):
            col = MUTED if i == 0 else (GREEN if c in ("validated", "pass", "deterministic", "conforms") or "0 misses" in c else TEXT)
            d.text((x, y), c, font=F(B if i == 0 else R, 28), fill=col)
        y += 70
    d.text((80, 930), "make spec-check validates both mappings; make compare runs check, render, events and bench for each.",
           font=F(R, 26), fill=MUTED)
    img.save(p)

@scene("code_jump", "Now the code. Here is the jump logic: Rust on the left, Zig on the right. Same counter, same limit, "
       "same fall through to the else target. The difference is where the counters go. The Rust clones a hash map "
       "under a lock, on the audio thread. The Zig publishes into a fixed table of atomics, because the specification "
       "says the callback never blocks, and cloning a map allocates.")
def _(p):
    img, d = base("4 · RUST vs ZIG", "Jump rows: same logic, no allocation", "rust/src/audio.rs:1051  ·  zig/src/audio.zig:1160  (abridged)")
    code(d, 80, 240, 870, 780, "Rust · audio.rs", RUSTC, [
        "let limit = js.times.max(1);",
        "let value = jump_counters",
        "    .entry(pid).or_insert(0);",
        "let incremented = value.saturating_add(1);",
        "if incremented < limit {",
        "    *value = incremented;",
        "    *cur_phrase = position(js.target_id);",
        "} else {",
        "    *value = 0;",
        "    *cur_phrase = js.fail_target_id",
        "        .and_then(|id| position(id))",
        "        .unwrap_or((*cur_phrase + 1) % len);",
        "}",
        "!if let Ok(mut jc) = jump_counters().try_lock() {",
        "!    *jc = jump_counters.clone(); // allocates",
        "}"], 22)
    code(d, 970, 240, 870, 780, "Zig · audio.zig", ZIGC, [
        "const limit = @max(js.times, 1);",
        "const value = self.jumps",
        "    .getOrPut(pid) orelse &overflow;",
        "const incremented = value.* +| 1;",
        "if (incremented < limit) {",
        "    value.* = incremented;",
        "    self.cur_phrase = self.positionOf(target);",
        "} else {",
        "    value.* = 0;",
        "    const fail = if (js.fail_target_id) |id|",
        "        self.positionOf(id) else null;",
        "    self.cur_phrase = fail orelse self.advance(i);",
        "}",
        "!sh.setJumpCounter(pid, value.*);",
        "!// a fixed table of atomics: no lock, no alloc",
        ""], 22)
    img.save(p)

@scene("code_panic", "Here is the panic from the known gaps chapter. The Rust clamps the peak between two and the number "
       "of notes minus one. With fewer than three notes the minimum is larger than the maximum, and clamp panics. "
       "The Zig checks first, and tells the performer exactly how to fix the jins.")
def _(p):
    img, d = base("4 · RUST vs ZIG", "A one-note jins: panic vs message", "rust/src/sequencer.rs:298  ·  zig/src/sequencer.zig:539")
    code(d, 80, 240, 870, 560, "Rust · sequencer.rs", RUSTC, [
        "let n_freqs = frequencies.len();",
        "!let peak = (peak_degree * n_freqs / 8)",
        "!    .clamp(2, n_freqs.saturating_sub(1));",
        "// n_freqs = 1:  clamp(2, 0)",
        "// panics: assertion failed: min <= max"], 24)
    code(d, 970, 240, 870, 560, "Zig · sequencer.zig", ZIGC, [
        "const n_freqs = deduped.items.len;",
        "!if (n_freqs < 3) {",
        "!    return .{ .err = try std.fmt.allocPrint(gpa,",
        "        \"a phrase needs at least 3 notes in its",
        "         scale, but this one has {d}; give the",
        "         jins more ratios ...\", ...) };",
        "}",
        "const peak = @max(2, @min(peak_degree *",
        "    n_freqs / 8, n_freqs - 1));"], 24)
    d.rounded_rectangle([80, 840, 1840, 1000], radius=14, fill=CARD, outline=GREEN, width=2)
    d.text((110, 870), "Requirement:  never — an input that crashes the app", font=F(B, 32), fill=GREEN)
    d.text((110, 925), "Rust: counterexample in the Known gaps chapter.   Zig: rejected, with a test.", font=F(R, 28), fill=TEXT)
    img.save(p)

@scene("code_channel", "And the channel between the app and the audio. Both hold five hundred and twelve commands, as the "
       "specification requires, and both drain them without waiting. But when a phrase is replaced, the Rust drops the old "
       "one inside the callback, which frees memory on the audio thread. The Zig hands it back on a second ring, and the "
       "app frees it.")
def _(p):
    img, d = base("4 · RUST vs ZIG", "App → Audio: 512 commands, never waiting", "rust/src/main.rs:84, audio.rs:456  ·  zig/src/audio.zig:656, 832, 991")
    code(d, 80, 240, 870, 700, "Rust · main.rs, audio.rs", RUSTC, [
        "let (tx, rx) = bounded::<AudioCmd>(512);",
        "",
        "while let Ok(cmd) = rx.try_recv() {",
        "  match cmd {",
        "    AudioCmd::ReplacePhrase(p) => {",
        "      if let Some(pp) = phrases.iter_mut()",
        "          .find(|pp| pp.phrase.id == p.id) {",
        "!        pp.phrase.src = p.src; // old dropped:",
        "!        pp.phrase.bar = p.bar; // freed here",
        "        pp.rebuild(sr, bpm);",
        "      }", "    }"], 23)
    code(d, 970, 240, 870, 700, "Zig · audio.zig", ZIGC, [
        "cmds: channel.Ring(AudioCmd, 512) = .{},",
        "",
        "const cmd = self.cmds.tryRecv() orelse return;",
        "switch (cmd) {",
        "  .replace_phrase => |p| {",
        "    if (self.positionOf(p.id)) |i| {",
        "      const old = self.phrases[i].phrase;",
        "      self.phrases[i].phrase = p;",
        "      self.phrases[i].rebuild(self.sr, self.bpm);",
        "!      self.release(.{ .phrase = old });",
        "!      // back to the App on the garbage ring",
        "    } else self.release(.{ .phrase = p });"], 23)
    d.text((80, 970), "Spec: “The audio callback never blocks” — try_recv only, nothing freed or allocated in the callback.",
           font=F(R, 26), fill=MUTED)
    img.save(p)

DEMO_TEXT = ("Now the Zig binary itself. Make builds it. We start it, and load default dot m q. From here on, no "
             "narration: just the music, recorded from the Zig process as it played.")
OUTRO_TEXT = "One specification. Two implementations. Checked by machine, and by ear."

def tts(text, path):
    run([PIPER, "--model", VOICE, "--output_file", path], input=text.encode(), stderr=subprocess.DEVNULL)
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()

def still_segment(png, wav, secs, path, lead=0.6, fade_in=True):
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-t", f"{secs:.3f}", "-i", png,
         "-i", wav, "-filter_complex",
         f"[1:a]adelay={int(lead*1000)}|{int(lead*1000)},apad,atrim=0:{secs:.3f},aformat=sample_rates=48000:channel_layouts=stereo,"
         f"volume=1.6[a];[0:v]{'fade=t=in:st=0:d=0.4,' if fade_in else ''}fade=t=out:st={secs-0.4:.3f}:d=0.4,format=yuv420p[v]",
         "-map", "[v]", "-map", "[a]", "-t", f"{secs:.3f}",
         "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-c:a", "aac", "-b:a", "256k", path])

parts = []
for id, text, fn in scenes:
    png = os.path.join(work, f"{id}.png"); wav = os.path.join(work, f"{id}.wav"); mp4 = os.path.join(work, f"{id}.mp4")
    fn(png)
    dur = tts(text, wav)
    still_segment(png, wav, dur + 1.6, mp4, fade_in=bool(parts))  # the first frame is the title, never black
    print(f"{id}: {dur:.1f}s"); parts.append(mp4)

# ── the live take: narration over the shell, music unnarrated, fade before the cycle wraps ──
marks = json.load(open(os.path.join(take, "marks.json")))
w = wave.open(os.path.join(take, "live.wav")); sr, ch = w.getframerate(), w.getnchannels()
a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, ch).astype(np.float32) / 32768
win = sr // 100
rms = np.sqrt(np.mean(a[: len(a) // win * win, 0].reshape(-1, win) ** 2, axis=1))
onset = int(np.argmax(rms > 10 ** (-50 / 20))) * win / sr
demo_wav = os.path.join(work, "demo.wav"); demo_dur = tts(DEMO_TEXT, demo_wav)
t_start = 0.8
music_at = marks["load_enter"] + 0.02            # take time of the first sound
cycle = 256.0                                     # one cycle of default.mq (--render length)
BACK_TO_ROW_1 = 77.21                             # take time the cursor first returns to event 1 after rows 24/26/27
t_end = BACK_TO_ROW_1                             # the fade ends exactly as it jumps back
fade = 5.0
pre_music = music_at - t_start                    # seconds of shell before the music
hold = max(0.0, demo_dur + 1.4 - pre_music)       # freeze the first frame if the narration is longer
seg_len = hold + (t_end - t_start)
print(f"demo narration {demo_dur:.1f}s, shell {pre_music:.1f}s, hold {hold:.1f}s, take {seg_len:.1f}s")
delay = hold + music_at - t_start - onset
term = os.path.join(work, "term.mp4")
render = subprocess.Popen([sys.executable, os.path.join(D, "term_render.py"), take, "112", "30", str(FPS), "--raw",
                           str(t_start), str(t_end)], stdout=subprocess.PIPE)
music = f"[1:a]adelay={int(delay*1000)}|{int(delay*1000)},apad,atrim=0:{seg_len:.3f},loudnorm=I=-14:TP=-1.5:LRA=11," \
        f"aformat=sample_rates=48000:channel_layouts=stereo,afade=t=out:st={seg_len-fade:.3f}:d={fade}[m]"
voice = f"[2:a]adelay=500|500,apad,atrim=0:{seg_len:.3f},aformat=sample_rates=48000:channel_layouts=stereo,volume=1.6[n]"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
     "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "1920x1080", "-r", str(FPS), "-i", "-",
     "-i", os.path.join(take, "live.wav"), "-i", demo_wav,
     "-filter_complex", f"{music};{voice};[m][n]amix=inputs=2:normalize=0[a];"
                        f"[0:v]tpad=start_duration={hold:.3f}:start_mode=clone,fade=t=in:st=0:d=0.4,"
                        f"fade=t=out:st={seg_len-fade:.3f}:d={fade},format=yuv420p[v]",
     "-map", "[v]", "-map", "[a]", "-t", f"{seg_len:.3f}",
     "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-c:a", "aac", "-b:a", "256k", term], stdin=render.stdout)
if render.wait() != 0: sys.exit("term_render failed")
parts.append(term)

outro_png = os.path.join(work, "outro.png"); Image.open(os.path.join(D, "card_4.png")).save(outro_png)
outro_wav = os.path.join(work, "outro.wav"); od = tts(OUTRO_TEXT, outro_wav)
outro = os.path.join(work, "outro.mp4"); still_segment(outro_png, outro_wav, od + 3.0, outro, lead=1.0); parts.append(outro)

inputs = sum([["-i", p] for p in parts], [])
fc = "".join(f"[{i}:v][{i}:a]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=1:a=1[v][a]"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *inputs, "-filter_complex", fc, "-map", "[v]", "-map", "[a]",
     "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k",
     "-movflags", "+faststart", out])
print("wrote", out)
