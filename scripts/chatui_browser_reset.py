#!/usr/bin/env python3
"""Real embedded React UI check; optional Chrome/websocket-client test dependency.
No imports from disposable projects, no model network and no live account use.
"""
import base64
import json
from pathlib import Path
import subprocess
import time
import urllib.request
import websocket


def verify_browser(base, fixture):
    profile = fixture / "browser-profile"
    chrome_log = (fixture / "chrome.log").open("w")
    chrome = subprocess.Popen(["google-chrome", "--headless=new", "--no-sandbox", "--disable-gpu",
        "--disable-dev-shm-usage", "--disable-background-networking", "--no-first-run",
        "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
        "--remote-allow-origins=http://127.0.0.1", "--user-data-dir=" + str(profile), "about:blank"],
        stdout=chrome_log, stderr=subprocess.STDOUT)
    connection = None
    try:
        deadline = time.monotonic() + 15
        while not (profile / "DevToolsActivePort").exists() and time.monotonic() < deadline:
            assert chrome.poll() is None, "Chrome exited"
            time.sleep(.05)
        port = (profile / "DevToolsActivePort").read_text().splitlines()[0]
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version") as response:
            version = json.load(response)
        connection = websocket.create_connection(version["webSocketDebuggerUrl"], origin="http://127.0.0.1", timeout=20)
        sequence, events = 0, []

        def call(method, params=None, session=None):
            nonlocal sequence
            sequence += 1
            request = {"id": sequence, "method": method, "params": params or {}}
            if session:
                request["sessionId"] = session
            connection.send(json.dumps(request))
            while True:
                result = json.loads(connection.recv())
                if result.get("id") == sequence:
                    assert "error" not in result, result
                    return result.get("result", {})
                events.append(result)

        target = call("Target.createTarget", {"url": "about:blank"})["targetId"]
        session = call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        def evaluate(expression):
            result = call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True}, session)
            assert "exceptionDetails" not in result, result.get("exceptionDetails")
            return result.get("result", {}).get("value")
        def wait(expression):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if evaluate(expression):
                    return
                time.sleep(.05)
            raise AssertionError("React condition timed out: " + expression)
        def type_into(selector, text):
            evaluate(f"document.querySelector({json.dumps(selector)}).focus()")
            call("Input.insertText", {"text": text}, session)
        def click_text(text):
            evaluate(f"[...document.querySelectorAll('.project-panel:not([hidden]) button')].find(b=>b.textContent.trim()==={json.dumps(text)}).click()")

        call("Runtime.enable", session=session)
        call("Page.enable", session=session)
        call("Emulation.setDeviceMetricsOverride", {"width": 1440, "height": 1100, "deviceScaleFactor": 1, "mobile": False}, session)
        call("Page.navigate", {"url": base}, session)
        wait("Boolean(document.querySelector('input[name=username]'))")
        type_into("input[name=username]", "reset_user")
        type_into("input[name=password]", "test-reset-password")
        evaluate("document.querySelector('.auth form').requestSubmit()")
        wait("Boolean(document.querySelector('.project-panel:not([hidden]) .composer textarea'))")
        wait("Boolean(document.querySelector('.project-panel:not([hidden]) .composer select')?.value)")
        assert "GoServer" not in evaluate("document.querySelector('.projects').textContent")
        assert "Resettable project" in evaluate("document.querySelector('.projects').textContent")
        assert "resume" in evaluate("document.querySelector('.project-panel:not([hidden]) .messages').textContent").lower()
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_DURABLE_RESUME")
        wait("!document.querySelector('.project-panel:not([hidden]) .composer button').disabled")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].some(m=>m.textContent.includes('Durable resume verified'))")
        click_text("Project memory")
        wait("Boolean(document.querySelector('.project-panel:not([hidden]) .memory-files button'))")
        evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .memory-files button')].find(b=>b.textContent.includes('Message schema')).click()")
        wait("document.querySelector('.project-panel:not([hidden]) .memory-pane pre').textContent.includes('DurableProtocolMarker')")
        click_text("Book")
        click_text("Light PDF")
        wait("document.querySelector('.project-panel:not([hidden]) #bookPreview').src.includes('/main.pdf?')")
        light = evaluate("document.querySelector('.project-panel:not([hidden]) #bookPreview').src")
        click_text("Dark PDF")
        dark = evaluate("document.querySelector('.project-panel:not([hidden]) #bookPreview').src")
        assert light != dark and "/main-dark.pdf?" in dark
        for url in [light, dark]:
            assert evaluate(f"fetch({json.dumps(url)}).then(async r=>r.ok&&(await r.text()).startsWith('%PDF'))")
        click_text("Project memory")
        screenshot = call("Page.captureScreenshot", {"format": "png"}, session)
        (fixture / "react-reset.png").write_bytes(base64.b64decode(screenshot["data"]))
        exceptions = [e for e in events if e.get("method") == "Runtime.exceptionThrown"]
        assert not exceptions, exceptions
        return {"result": "pass", "browser": version["Browser"], "checks": ["password login", "no phantom examples",
                "empty-chat durable resume through actual React composer", "protobuf in Project memory", "separate light/dark PDF routes", "no uncaught browser exceptions"]}
    except Exception:
        if connection:
            try:
                (fixture / "failed-react-state.json").write_text(json.dumps(evaluate("({text:document.body.innerText,html:document.body.innerHTML.slice(0,10000)})"), indent=2))
            except Exception:
                pass
        raise
    finally:
        if connection:
            connection.close()
        chrome.terminate()
        chrome.wait(timeout=10)
        chrome_log.close()
