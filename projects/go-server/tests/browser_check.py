#!/usr/bin/env python3
"""R1..R6: exercise the real embedded browser app, two isolated seats, and export.
No provider API, generated stand-in, manually supplied screenshot, or chat input.
"""
import base64
import json
import io
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import websocket
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".cache"
EVIDENCE = ROOT / "evidence/playable-v1"
CACHE.mkdir(exist_ok=True)
EVIDENCE.mkdir(parents=True, exist_ok=True)


class CDP:
    def __init__(self, url):
        self.socket = websocket.create_connection(url, timeout=20, origin="http://127.0.0.1")
        self.sequence = 0
        self.events = []

    def call(self, method, params=None, session=None):
        self.sequence += 1
        message = {"id": self.sequence, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        self.socket.send(json.dumps(message))
        while True:
            result = json.loads(self.socket.recv())
            if result.get("id") == self.sequence:
                assert "error" not in result, (method, result.get("error"))
                return result.get("result", {})
            self.events.append(result)

    def evaluate(self, session, expression):
        result = self.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True,
                                                "returnByValue": True}, session)
        assert "exceptionDetails" not in result, result.get("exceptionDetails")
        return result.get("result", {}).get("value")

    def wait(self, session, expression, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.evaluate(session, expression):
                return
            time.sleep(.05)
        raise AssertionError("Browser condition timed out: " + expression)

    def page(self, url):
        context = self.call("Target.createBrowserContext")["browserContextId"]
        target = self.call("Target.createTarget", {"url": "about:blank", "browserContextId": context})["targetId"]
        session = self.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        self.call("Runtime.enable", session=session)
        self.call("Network.enable", session=session)
        self.call("Page.enable", session=session)
        self.call("Emulation.setDeviceMetricsOverride", {"width": 1360, "height": 1100,
                                                         "deviceScaleFactor": 1, "mobile": False}, session)
        self.call("Page.navigate", {"url": url}, session)
        self.wait(session, "Boolean(window.goServer)")
        return session, context

    def click(self, session, element):
        self.evaluate(session, f"document.getElementById({json.dumps(element)}).click()")

    def key(self, session, key, code=None):
        for kind in ["keyDown", "keyUp"]:
            self.call("Input.dispatchKeyEvent", {"type": kind, "key": key, "code": code or key,
                       "windowsVirtualKeyCode": {"Enter": 13, "ArrowRight": 39}.get(key, 0)}, session)


def main():
    with tempfile.TemporaryDirectory(dir=CACHE, prefix="browser-") as fixture:
        fixture = Path(fixture)
        server_log = open(fixture / "server.log", "w+")
        chrome_log = open(fixture / "chrome.log", "w+")
        server = subprocess.Popen([str(CACHE / "goserver"), "-addr", "127.0.0.1:0",
                                   "-data", str((fixture / "runtime").relative_to(ROOT))],
                                  cwd=ROOT, stdout=subprocess.PIPE, stderr=server_log, text=True)
        chrome = None
        cdp = None
        page = None
        try:
            line = server.stdout.readline().strip()
            assert line.startswith("GoServer ready at http://127.0.0.1:"), line
            base = line.split(" at ", 1)[1]
            profile = fixture / "profile"
            chrome = subprocess.Popen(["google-chrome", "--headless=new", "--no-sandbox",
                "--disable-gpu", "--disable-dev-shm-usage", "--disable-background-networking",
                "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0",
                "--remote-debugging-address=127.0.0.1", "--remote-allow-origins=http://127.0.0.1",
                "--user-data-dir=" + str(profile), "about:blank"], stdout=chrome_log, stderr=chrome_log)
            deadline = time.monotonic() + 15
            while not (profile / "DevToolsActivePort").exists() and time.monotonic() < deadline:
                assert chrome.poll() is None, "Chrome exited before startup"
                time.sleep(.05)
            port = (profile / "DevToolsActivePort").read_text().splitlines()[0]
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version") as response:
                browser = json.load(response)
            cdp = CDP(browser["webSocketDebuggerUrl"])
            page, context = cdp.page(base)
            downloads = fixture / "downloads"
            downloads.mkdir()
            cdp.call("Browser.setDownloadBehavior", {"behavior": "allow", "downloadPath": str(downloads),
                                                       "browserContextId": context})
            assert cdp.evaluate(page, "goServer.state().size===11 && goServer.state().players===4")
            cdp.click(page, "think")
            cdp.wait(page, "goServer.state().ply===1")
            first = cdp.evaluate(page, "goServer.selectedPath()[0]")
            cdp.click(page, "think")
            cdp.click(page, "back")
            time.sleep(.7)
            assert cdp.evaluate(page, "goServer.state().ply===0 && goServer.nodeCount()===2")
            target = 2 if first.get("kind") == "move" and first.get("point") == 1 else 1
            cdp.evaluate(page, "document.querySelector('[role=gridcell]').focus()")
            for _ in range(target):
                cdp.key(page, "ArrowRight")
            assert "Open" in cdp.evaluate(page, "document.activeElement.getAttribute('aria-label')")
            cdp.key(page, "Enter")
            cdp.wait(page, "goServer.nodeCount()===3")
            assert "Black" in cdp.evaluate(page, "document.getElementById('point-label').textContent")
            cdp.click(page, "root")
            assert cdp.evaluate(page, "document.getElementById('variation').options.length===2")
            cdp.click(page, "live")
            cdp.click(page, "autoplay")
            cdp.wait(page, "goServer.state().ply>=8", timeout=25)
            cdp.click(page, "autoplay")
            assert cdp.evaluate(page, "document.getElementById('error').hidden")
            cdp.click(page, "back")
            selected_ply = cdp.evaluate(page, "goServer.state().ply")
            cdp.click(page, "gif")
            cdp.wait(page, "document.getElementById('artifact').textContent.includes('Verified GIF')")
            deadline = time.monotonic() + 5
            while not list(downloads.glob("*.gif")) and time.monotonic() < deadline:
                time.sleep(.05)
            exported = next(downloads.glob("*.gif")).read_bytes()
            assert exported[:6] in [b"GIF89a", b"GIF87a"]
            assert f"ends at move {selected_ply}" in cdp.evaluate(page, "document.getElementById('artifact').textContent")
            (EVIDENCE / "selected-line.gif").write_bytes(exported)
            screenshot = cdp.call("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": True}, page)
            (EVIDENCE / "board.png").write_bytes(base64.b64decode(screenshot["data"]))
            selected_state = cdp.evaluate(page, "goServer.state()")
            animation = Image.open(io.BytesIO(exported))
            assert animation.n_frames == selected_ply + 1
            animation.seek(animation.n_frames - 1)
            final_image = animation.convert("RGB")
            palette = [(221, 182, 118), (30, 30, 30), (248, 248, 248), (205, 57, 67),
                       (45, 118, 215), (34, 151, 98), (234, 181, 27)]
            step = 432 // (selected_state["size"] - 1)
            for point, stone in enumerate(selected_state["board"]):
                xy = (44 + point % selected_state["size"] * step, 44 + point // selected_state["size"] * step)
                assert final_image.getpixel(xy) == palette[stone], ("GIF endpoint mismatch", point)
            ax = cdp.call("Accessibility.getFullAXTree", session=page)
            labels = [n.get("name", {}).get("value", "") for n in ax["nodes"] if n.get("role", {}).get("value") == "gridcell"]
            assert len(labels) == 121 and any("last move" in label for label in labels)
            (EVIDENCE / "board-labels.txt").write_text("\n".join(labels) + "\n")

            alice, _ = cdp.page(base)
            cdp.evaluate(alice, "document.getElementById('size').value='5';document.getElementById('name').value='Alice'")
            cdp.click(alice, "host")
            cdp.wait(alice, "document.getElementById('room').value.length===48")
            room = cdp.evaluate(alice, "document.getElementById('room').value")
            bob, _ = cdp.page(base + "/?game=" + room)
            cdp.evaluate(bob, "document.getElementById('name').value='Bob'")
            cdp.click(bob, "join")
            cdp.wait(alice, "document.getElementById('network').textContent.includes('2/2 players')")
            cdp.wait(bob, "document.getElementById('network').textContent.includes('2/2 players')")
            for session, point, ply in [(alice, 0, 1), (bob, 1, 2)]:
                cdp.evaluate(session, f"document.querySelectorAll('[role=gridcell]')[{point}].focus()")
                cdp.key(session, "Enter")
                cdp.wait(alice, f"goServer.state().ply==={ply}")
                cdp.wait(bob, f"goServer.state().ply==={ply}")
            cdp.click(alice, "back")
            assert cdp.evaluate(alice, "document.getElementById('pass').disabled")
            cdp.click(alice, "live")
            cdp.call("Page.reload", session=alice)
            cdp.wait(alice, "Boolean(window.goServer) && goServer.state().ply===2 && document.getElementById('network').textContent.includes('You are Black')")
            cdp.click(alice, "pass")
            cdp.wait(bob, "goServer.state().ply===3")
            cdp.click(bob, "pass")
            cdp.wait(alice, "goServer.state().finished")
            cdp.wait(bob, "goServer.state().finished")
            assert cdp.evaluate(alice, "JSON.stringify(goServer.state())") == cdp.evaluate(bob, "JSON.stringify(goServer.state())")
            cdp.call("Page.reload", session=alice)
            cdp.wait(alice, "Boolean(window.goServer) && goServer.state().finished && document.getElementById('network').textContent.includes('You are Black')")
            cdp.call("Network.emulateNetworkConditions", {"offline": True, "latency": 0,
                     "downloadThroughput": 0, "uploadThroughput": 0}, alice)
            cdp.wait(alice, "document.getElementById('error').textContent.includes('Automatic polling paused')")
            def alice_requests():
                return sum(e.get("method") == "Network.requestWillBeSent" and e.get("sessionId") == alice
                           and "/api/games/" in e["params"]["request"]["url"] for e in cdp.events)
            before = alice_requests()
            time.sleep(2.2)
            cdp.evaluate(alice, "true")
            assert alice_requests() == before, "failed polling repeated automatically"
            cdp.call("Network.emulateNetworkConditions", {"offline": False, "latency": 0,
                     "downloadThroughput": -1, "uploadThroughput": -1}, alice)
            cdp.click(alice, "join")
            cdp.wait(alice, "document.getElementById('error').hidden && goServer.state().finished")
            # Only the original tab's session credential resumes its own seat.
            with urllib.request.urlopen(base + "/api/games/" + room) as response:
                persisted = json.load(response)
            assert persisted["game"]["position"]["finished"]
            traces = []
            for event in list(cdp.events):
                if event.get("method") != "Network.responseReceived":
                    continue
                data = event["params"]
                if "/api/games" not in data["response"]["url"]:
                    continue
                try:
                    payload = cdp.call("Network.getResponseBody", {"requestId": data["requestId"]}, event.get("sessionId"))
                    result = json.loads(payload["body"])
                    if result.get("events"):
                        traces.append(result["events"])
                except (AssertionError, KeyError, ValueError):
                    pass
            failures = [event for event in cdp.events if event.get("method") == "Runtime.exceptionThrown"]
            assert not failures, failures
            report = {"revision": "playable-v1", "browser": browser["Browser"], "result": "pass",
                      "checks": ["four-player client-side MCTS", "keyboard move", "branch preserves siblings",
                                 "selected-path real GIF", "two isolated browser seats", "same authoritative final state",
                                 "own seat resumes after reload", "network history is read-only", "121 labeled keyboard cells", "GIF final pixels match every selected board point", "review cancels in-flight search", "failed polling pauses without retries and reconnects own seat", "no uncaught browser exceptions"],
                      "selected_gif_ply": selected_ply, "selected_state": selected_state, "gif_bytes": len(exported), "observed_scenarios": traces}
            (EVIDENCE / "browser.json").write_text(json.dumps(report, indent=2) + "\n")
            cdp.socket.close()
            print("ok: actual browser MCTS, keyboard play, branching, GIF, and Alice/Bob complete game")
        except Exception:
            if cdp and page:
                try:
                    detail = cdp.evaluate(page, "({state:window.goServer?.state(),nodes:window.goServer?.nodeCount(),focus:document.activeElement?.outerHTML,status:document.getElementById('status')?.textContent,error:document.getElementById('error')?.textContent})")
                    detail["exceptions"] = [event for event in cdp.events if event.get("method") == "Runtime.exceptionThrown"]
                    (CACHE / "failed-browser.json").write_text(json.dumps(detail, indent=2))
                    screenshot = cdp.call("Page.captureScreenshot", {"format": "png"}, page)
                    (CACHE / "failed-browser.png").write_bytes(base64.b64decode(screenshot["data"]))
                except Exception:
                    pass
            # Keep bounded readable logs outside the temporary fixture on failure.
            for file in [fixture / "server.log", fixture / "chrome.log"]:
                if file.exists():
                    (CACHE / ("failed-" + file.name)).write_text(file.read_text(errors="replace")[-12000:])
            raise
        finally:
            if chrome:
                chrome.terminate()
                chrome.wait(timeout=10)
            server.terminate()
            server.wait(timeout=10)
            server_log.close()
            chrome_log.close()


if __name__ == "__main__":
    main()
