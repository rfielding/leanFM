"""Run, for real, every terminal step the book tour shows, and keep what each printed (data/terminal.json):
a fresh shallow clone of LeanFM from GitHub, the Claude Desktop entry for it, the running server's health,
CtlTiny.lean checked by Lean (and caught when one of its claims is made false), and the cage's device log.
Paths are shown relative to ~/code. Usage: capture.py"""
import json, os, shutil, subprocess, tempfile, time
D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))
work = tempfile.mkdtemp(prefix="tour-")
clone = os.path.join(work, "leanFM")
steps = []

def run(cmd, cwd, show=None, keep=14):
    t = time.time()
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=600)
    out = (p.stdout + p.stderr).replace(work, "~/code").replace(ROOT, "~/code/leanFM").replace(os.path.expanduser("~"), "~")
    lines = [l.rstrip() for l in out.splitlines() if l.strip()]
    if len(lines) > keep: lines = lines[:keep - 1] + [f"... ({len(lines) - keep + 1} more lines)"]
    steps.append({"cwd": "~/code" if cwd == work else "~/code/leanFM", "cmd": show or cmd, "out": lines,
                  "secs": round(time.time() - t, 1), "status": p.returncode})
    print(f"$ {show or cmd}  ({p.returncode}, {time.time() - t:.1f}s)")

run("git clone --depth 1 https://github.com/rfielding/leanFM.git", work)
run("ls --width=90 | head -12", clone, "ls")
run("ls book/chapters", clone)
# the clone is built by `make serve` (a few minutes the first time); the rest runs in a built checkout
run(f"python3 scripts/claude_desktop_config.py --root {clone} --forward http://127.0.0.1:8080/mcp", clone,
    'python3 scripts/claude_desktop_config.py --root "$PWD" --forward http://127.0.0.1:8080/mcp')
run("curl -s http://127.0.0.1:8080/health", ROOT)
run("sed -n '/^def nextR/,/^def tt/p' book/examples/CtlTiny.lean | head -9", ROOT, "sed -n '/nextR/,/untilR/p' book/examples/CtlTiny.lean")
run("lake env lean book/examples/CtlTiny.lean && echo \"all $(grep -c '^#guard' book/examples/CtlTiny.lean) checks hold\"", ROOT,
    "lake env lean book/examples/CtlTiny.lean")
bad = os.path.join(work, "CtlTiny.lean")
shutil.copy(os.path.join(ROOT, "book/examples/CtlTiny.lean"), bad)
open(bad, "a").write('\n-- claim that b is inevitable from s0 (it is only possible)\n#guard inevitably b "s0"\n')
run(f"lake env lean {bad} 2>&1 | head -4", ROOT, "echo '#guard inevitably b \"s0\"' >> CtlTiny.lean && lake env lean CtlTiny.lean")
run("tail -n 3 logs/devices.log | cut -c1-150", ROOT, "tail -n 3 logs/devices.log")
json.dump(steps, open(os.path.join(D, "data", "terminal.json"), "w"), indent=1)
shutil.rmtree(work, ignore_errors=True)
