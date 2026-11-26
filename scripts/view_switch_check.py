#!/usr/bin/env python3
"""One address, two sources (selfhost.session.event-source, decision session-event-source).

Starts leanfm-server on a spare loopback port (its event lines in a scratch file), opens /view in
headless Chrome and checks: the page opens on Actual log, with the REAL LOG banner and Actual log
pressed; Simulated shows the SIMULATED banner with Simulated pressed; Actual log brings REAL LOG back;
the address stays /view; and the page's own LeanFMMcp events conform to LeanFMMcp.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepalive_check import BIN, spare_port  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROME = "/usr/bin/google-chrome"


def until_up(port):
    for _ in range(400):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    raise SystemExit("leanfm-server did not start")


def until_pressed(pg, which):
    """Wait (at most 60 s, by polling the page, which forbids eval) until the switch marks which."""
    for _ in range(600):
        if pg.locator("#" + which).get_attribute("aria-pressed") == "true":
            return
        pg.wait_for_timeout(100)
    raise SystemExit(f"{which} was never marked as shown")


def main():
    out = tempfile.NamedTemporaryFile(prefix="leanfm-switch-", suffix=".log", delete=False)
    port = spare_port()
    proc = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=ROOT, env={**os.environ, "LEANFM_PORT": str(port)},
                            stdout=out, stderr=subprocess.DEVNULL)
    try:
        until_up(port)
        with sync_playwright() as p:
            b = p.chromium.launch(**({"executable_path": CHROME} if os.path.exists(CHROME) else {}))
            pg = b.new_page(viewport={"width": 1400, "height": 1000})
            base = f"http://127.0.0.1:{port}/view"
            pg.goto(base)
            f = pg.frame_locator("#view")
            banner = f.locator(".source").first
            banner.wait_for(timeout=60000)
            pressed = lambda: {k: pg.locator("#" + k).get_attribute("aria-pressed") for k in ("actual", "simulated")}
            until_pressed(pg, "actual")
            assert "REAL LOG" in banner.inner_text(), banner.inner_text()
            assert pressed() == {"actual": "true", "simulated": "false"}, pressed()
            print("ok: /view opens on Actual log: the REAL LOG banner, Actual log pressed")
            pg.locator("#simulated").click()
            until_pressed(pg, "simulated")
            f.locator(".source.simulated").first.wait_for(timeout=60000)
            assert "SIMULATED" in f.locator(".source").first.inner_text()
            assert pressed() == {"actual": "false", "simulated": "true"}, pressed()
            print("ok: Simulated shows the SIMULATED banner and is the one pressed")
            pg.locator("#actual").focus()
            pg.keyboard.press("Enter")
            until_pressed(pg, "actual")
            f.locator(".source.log").first.wait_for(timeout=60000)
            assert pg.url.rstrip("/") == base, pg.url
            print("ok: Actual log, by keyboard, brings the REAL LOG banner back, and the address stayed /view")
            b.close()
        time.sleep(0.3)
    finally:
        proc.kill(); proc.wait()
        out.close()
    text = open(out.name).read()
    os.unlink(out.name)
    mine = [json.loads(l) for l in text.split("\n") if l.startswith('{"type":"leanFM"') and '"LeanFMMcp"' in l]
    labels = [e["label"] for e in mine]
    assert labels[:4] == ["Initialize", "Initialized", "ListTools", "Tools"] and labels.count("ReadLog") == 2, labels
    port = spare_port()
    proc = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=ROOT, env={**os.environ, "LEANFM_PORT": str(port)},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        until_up(port)
        lean = open(os.path.join(ROOT, "LeanFM/LLMGenerated/LeanFM.leanfm")).read()
        body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "session_conform", "arguments":
                {"lean": lean, "protocolName": "LeanFMMcp", "allowIncomplete": True,
                 "log": "\n".join(json.dumps(e) for e in mine)}}}
        req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(), {"Content-Type": "application/json"})
        sc = json.loads(urllib.request.urlopen(req, timeout=120).read())["result"]["structuredContent"]
    finally:
        proc.kill(); proc.wait()
    print("  the page's events:", " ".join(labels))
    if os.environ.get("LEANFM_DUMP"):
        open(os.environ["LEANFM_DUMP"], "w").write("\n".join(json.dumps(e) for e in mine))
    if sc["verdict"] != "conforms":
        raise SystemExit("the page's own events break LeanFMMcp: " + "; ".join(sc.get("issues") or [sc.get("reading", "")]))
    print("ok: the page's own events conform to LeanFMMcp: " + sc["reading"])


if __name__ == "__main__":
    main()
