#!/usr/bin/env python3
"""One make at a time in a checkout (selfhost.build.lock).

Starts two `make lock-probe` runs 0.3 s apart, with their own lock file and probe log so the check
does not wait on the make that is running it. Both must succeed, their intervals must not overlap,
and the second must say it is waiting.
"""
import os
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".cache")


def main():
    os.makedirs(CACHE, exist_ok=True)
    lock = os.path.join(CACHE, "make-lock-check.lock")
    log = os.path.join(CACHE, "lock-probe.log")
    if os.path.exists(log):
        os.remove(log)
    env = {k: v for k, v in os.environ.items() if k not in ("LEANFM_MAKE_LOCKED", "MAKEFLAGS", "MAKELEVEL", "MFLAGS")}
    env.update({"LEANFM_MAKE_LOCK": lock, "LOCK_PROBE_LOG": log})
    first = subprocess.Popen(["make", "--no-print-directory", "lock-probe"], cwd=ROOT, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    time.sleep(0.3)
    second = subprocess.Popen(["make", "--no-print-directory", "lock-probe"], cwd=ROOT, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out1 = first.communicate(timeout=60)[0].decode()
    out2 = second.communicate(timeout=60)[0].decode()
    assert first.returncode == 0 and second.returncode == 0, (first.returncode, out1, second.returncode, out2)
    lines = [l.split() for l in open(log).read().split("\n") if l.strip()]
    kinds = [k for k, _ in lines]
    assert kinds == ["start", "end", "start", "end"], ("the two runs overlapped", lines)
    times = [int(t) for _, t in lines]
    assert times == sorted(times), ("the probe times are out of order", lines)
    print(f"ok: two makes at once ran one after the other ({(times[2] - times[1]) / 1e6:.0f} ms between them)")
    assert "waiting for it" in out2, ("the second make did not say it was waiting", out2)
    print("ok: the second make said another make was running and waited")


if __name__ == "__main__":
    main()
