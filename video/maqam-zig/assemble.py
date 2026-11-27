"""Cards + the terminal take (with its live audio) -> one mp4. Usage: assemble.py <take> <out.mp4>"""
import json, os, subprocess, sys, wave, struct
import numpy as np

D = os.path.dirname(os.path.abspath(__file__))
take, out = sys.argv[1], sys.argv[2]
FPS = 30
marks = json.load(open(os.path.join(take, "marks.json")))

def run(cmd, **kw):
    print("+", " ".join(cmd[:6]), "..."); subprocess.run(cmd, check=True, **kw)

# Audio onset in the live capture (first 10 ms window above -50 dBFS).
w = wave.open(os.path.join(take, "live.wav"))
sr, ch = w.getframerate(), w.getnchannels()
a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, ch).astype(np.float32) / 32768
win = sr // 100
rms = np.sqrt(np.mean(a[: len(a) // win * win, 0].reshape(-1, win) ** 2, axis=1))
onset = int(np.argmax(rms > 10 ** (-50 / 20))) * win / sr
print("onset in live.wav:", onset, "s")

t_start = 0.8
t_end = marks["quit"] + 2.5
seg_len = t_end - t_start
# The first sound happens just after Enter on `load` (device latency ~20 ms).
delay = marks["load_enter"] + 0.02 - t_start - onset
print("audio offset:", delay)

seg = os.path.join(take, "term.mp4")
render = subprocess.Popen([sys.executable, os.path.join(D, "term_render.py"), take, "112", "30", str(FPS), "--raw",
                           str(t_start), str(t_end)], stdout=subprocess.PIPE)
afilter = f"adelay={int(delay*1000)}|{int(delay*1000)}" if delay >= 0 else f"atrim=start={-delay},asetpts=PTS-STARTPTS"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
     "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "1920x1080", "-r", str(FPS), "-i", "-",
     "-i", os.path.join(take, "live.wav"),
     "-filter_complex", f"[1:a]{afilter},apad,atrim=0:{seg_len:.3f},afade=t=out:st={seg_len-1.2:.3f}:d=1.2,"
                        f"loudnorm=I=-14:TP=-1.5:LRA=11,aformat=sample_rates=48000:channel_layouts=stereo[a]",
     "-map", "0:v", "-map", "[a]", "-t", f"{seg_len:.3f}",
     "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k", seg],
    stdin=render.stdout)
if render.wait() != 0: sys.exit("term_render failed")

def card(png, secs, name, bed_at=None):
    p = os.path.join(take, name)
    if bed_at is None:
        ain = ["-f", "lavfi", "-t", str(secs), "-i", "anullsrc=r=48000:cl=stereo"]
        af = ["-af", "aformat=sample_rates=48000:channel_layouts=stereo"]
    else:  # a quieter bed from the live take, starting bed_at seconds into the music
        ain = ["-ss", f"{onset + bed_at:.3f}", "-t", str(secs), "-i", os.path.join(take, "live.wav")]
        af = ["-af", f"loudnorm=I=-20:TP=-3,afade=t=in:st=0:d=0.8,afade=t=out:st={secs-0.8}:d=0.8,aformat=sample_rates=48000:channel_layouts=stereo"]
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-t", str(secs), "-i", png,
         *ain, *af,
         "-vf", f"fade=t=in:st=0:d=0.6,fade=t=out:st={secs-0.6}:d=0.6,format=yuv420p",
         "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-c:a", "aac", "-b:a", "256k", "-shortest", p])
    return p

parts = [card(os.path.join(D, "card_1.png"), 9, "c1.mp4", bed_at=150), card(os.path.join(D, "card_2.png"), 10, "c2.mp4", bed_at=159),
         card(os.path.join(D, "card_3.png"), 6, "c3.mp4", bed_at=169), seg, card(os.path.join(D, "card_4.png"), 7, "c4.mp4")]
inputs = sum([["-i", p] for p in parts], [])
fc = "".join(f"[{i}:v][{i}:a]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=1:a=1[v][a]"
run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *inputs, "-filter_complex", fc, "-map", "[v]", "-map", "[a]",
     "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k",
     "-movflags", "+faststart", out])
print("wrote", out)
