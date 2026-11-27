"""Drive a real bash in a pty: make, start maqam-live, type `load default.mq`, let one cycle
play, quit. Records every byte the terminal receives with its timestamp (capture.jsonl), so the
video can be rendered offline at any frame rate. Usage: capture.py <outdir> <cols> <rows> <secs>"""
import fcntl, json, os, pty, random, select, struct, sys, termios, threading, time, base64

out, cols, rows, play_secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
src = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "projects/Maqam/impl/zig/source")

pid, fd = pty.fork()
if pid == 0:
    os.chdir(src)
    env = {
        "PATH": os.environ["PATH"], "HOME": os.environ["HOME"], "TERM": "xterm-256color",
        "LANG": "C.UTF-8", "PS1": "\\[\\e[1;32m\\]maqam/impl/zig/source\\[\\e[0m\\] $ ",
        "XDG_RUNTIME_DIR": os.environ.get("XDG_RUNTIME_DIR", ""),
        "MAQAM_EVENT_LOG": os.path.join(out, "events.jsonl"),
    }
    os.execve("/bin/bash", ["bash", "--norc", "--noprofile", "-i"], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
t0 = time.monotonic()
log = open(os.path.join(out, "capture.jsonl"), "w")
marks = {}
done = threading.Event()

def reader():
    while not done.is_set():
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        log.write(json.dumps({"t": time.monotonic() - t0, "b": base64.b64encode(data).decode()}) + "\n")
    done.set()

th = threading.Thread(target=reader, daemon=True)
th.start()

def type_text(s, enter=True):
    for ch in s:
        os.write(fd, ch.encode())
        time.sleep(random.uniform(0.05, 0.11))
    if enter:
        time.sleep(0.35)
        os.write(fd, b"\r")

time.sleep(1.5)
type_text("make")
time.sleep(4.0)
type_text("./zig-out/bin/maqam-live")
time.sleep(1.5)
import subprocess
marks["rec_start"] = time.monotonic() - t0
rec = subprocess.Popen(["pw-record", "--target", "alsa_playback.maqam-live", "--rate", "48000",
                        "--channels", "2", os.path.join(out, "live.wav")])
time.sleep(1.5)
type_text("load default.mq", enter=False)
time.sleep(0.5)
marks["load_enter"] = time.monotonic() - t0
os.write(fd, b"\r")
time.sleep(play_secs)
marks["quit"] = time.monotonic() - t0
rec.terminate(); rec.wait()
os.write(fd, b"\x11")  # Ctrl-Q
time.sleep(2.0)
type_text("exit")
time.sleep(1.0)
marks["end"] = time.monotonic() - t0
done.set()
th.join(1)
log.close()
json.dump(marks, open(os.path.join(out, "marks.json"), "w"))
print(marks)
