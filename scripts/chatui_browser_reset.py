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
from PIL import Image


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
        call("Target.activateTarget", {"targetId": target})
        def evaluate(expression):
            result = call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True}, session)
            assert "exceptionDetails" not in result, result.get("exceptionDetails")
            return result.get("result", {}).get("value")
        def wait(expression, seconds=30):
            deadline = time.monotonic() + seconds
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
        wait("Boolean([...document.querySelectorAll('button')].find(b=>b.textContent.trim() === 'Unlock API keys'))")
        evaluate("[...document.querySelectorAll('button')].find(b=>b.textContent.trim() === 'Unlock API keys').click()")
        wait("Boolean(document.querySelector('input[name=username]'))")
        assert evaluate("document.querySelector('.auth-tabs [aria-selected=true]').textContent") == "Log in"
        assert not evaluate("document.querySelector('.auth form details').open")
        for label in ["Create account", "Log in"]:
            evaluate(f"[...document.querySelectorAll('.auth-tabs button')].find(b=>b.textContent==={json.dumps(label)}).focus()")
            call("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13, "text": "\r", "unmodifiedText": "\r"}, session)
            call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13}, session)
            wait(f"document.querySelector('.auth form .primary').textContent === {json.dumps(label)}")
            assert evaluate("document.querySelector('.auth-tabs [aria-selected=true]').textContent") == label
        assert not evaluate("document.querySelector('.auth form details').open")
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
        image_file = fixture / "chat-upload.png"
        Image.new("RGB", (12, 8), "red").save(image_file)
        document = call("DOM.getDocument", session=session)["root"]["nodeId"]
        field = call("DOM.querySelector", {"nodeId": document, "selector": ".project-panel:not([hidden]) input[type=file]"}, session)["nodeId"]
        def choose_image():
            call("DOM.setFileInputFiles", {"nodeId": field, "files": [str(image_file.resolve())]}, session)
            wait("document.querySelectorAll('.project-panel:not([hidden]) .attachment-preview').length === 1")
            wait("!document.querySelector('.project-panel:not([hidden]) .attachment-controls button').disabled")
        choose_image()
        evaluate("document.querySelector('.project-panel:not([hidden]) .attachment-preview button[aria-label^=\"Remove attachment\"]').click()")
        wait("document.querySelectorAll('.project-panel:not([hidden]) .attachment-preview').length === 0")
        choose_image()
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_IMAGE_INPUT")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].some(m=>m.textContent.includes('Image pixels received: 255,0,0'))")
        wait("document.querySelectorAll('.project-panel:not([hidden]) .attachment-preview').length === 0")
        evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .message.user')].find(m=>m.textContent.includes('TEST_IMAGE_INPUT')).querySelector('.message-actions button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].filter(m=>m.textContent.includes('Image pixels received: 255,0,0')).length === 2")
        assert evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .message.user img')].some(i=>i.complete&&i.naturalWidth>0)")
        click_text("Project memory")
        wait("Boolean(document.querySelector('.project-panel:not([hidden]) .memory-files button'))")
        evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .memory-files button')].find(b=>b.textContent.includes('Message schema')).click()")
        wait("document.querySelector('.project-panel:not([hidden]) .memory-pane pre')?.textContent.includes('DurableProtocolMarker')")
        click_text("Book")
        click_text("Light PDF")
        wait("document.querySelector('.project-panel:not([hidden]) #bookPreview').src.includes('/main.pdf?')")
        light = evaluate("document.querySelector('.project-panel:not([hidden]) #bookPreview').src")
        click_text("Dark PDF")
        dark = evaluate("document.querySelector('.project-panel:not([hidden]) #bookPreview').src")
        assert light != dark and "/main-dark.pdf?" in dark
        for url in [light, dark]:
            assert evaluate(f"fetch({json.dumps(url)}).then(async r=>r.ok&&(await r.text()).startsWith('%PDF'))")
        type_into(".sidebar form input", "Fresh server")
        evaluate("document.querySelector('.sidebar form').requestSubmit()")
        wait("document.querySelector('.project-panel:not([hidden]) .topbar strong')?.textContent === 'Fresh server'")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.value")
        assert "What problem are you trying to solve?" in evaluate("document.querySelector('.project-panel:not([hidden]) .messages').textContent")
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_SPECIFY_SERVER")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].some(m=>m.textContent.includes('Completed patch fixture'))")
        assert evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].at(-1).querySelector('.result-badge.success') !== null")
        click_text("Grammar")
        wait("document.querySelector('.project-panel:not([hidden]) .grammar-pane')?.textContent.includes('FixtureRequest')")
        click_text("Tasks")
        wait("document.querySelector('.project-panel:not([hidden]) .diagram-stage svg')?.textContent.includes('FixtureRequest')")
        click_text("States · state machine")
        wait("document.querySelector('.project-panel:not([hidden]) .diagram-stage svg')?.textContent.includes('waiting')")
        click_text("Properties · CTL")
        wait("document.querySelector('.project-panel:not([hidden]) .task-clause')?.textContent.includes('Correlated completion')")
        click_text("Project memory")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) button')].some(b=>b.textContent === 'Accept requirements' && !b.disabled)")
        click_text("Accept requirements")
        wait("document.querySelector('.project-panel:not([hidden]) .specification-review article')?.textContent.includes('Accepted current revision')")
        click_text("Chat")
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_SPECIFY_IMPLEMENTATION")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].filter(m=>m.textContent.includes('Completed patch fixture')).length === 2")
        click_text("Project memory")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) button')].some(b=>b.textContent === 'Accept implementation specification' && !b.disabled)")
        click_text("Accept implementation specification")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .specification-review article')].every(a=>a.textContent.includes('Accepted current revision'))")
        click_text("Chat")
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_WRITE_SOURCE implement the server now")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].some(m=>m.textContent.includes('Created and checked source/main.go'))", seconds=60)
        assert evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].at(-1).querySelector('.result-badge.success') !== null")
        click_text("Source")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .source-files button')].some(b=>b.textContent.includes('main.go'))")
        evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .source-files button')].find(b=>b.textContent.includes('main.go')).click()")
        wait("document.querySelector('.project-panel:not([hidden]) .source-pane .source-view pre')?.textContent.includes('func main')")
        click_text("Project memory")
        screenshot = call("Page.captureScreenshot", {"format": "png"}, session)
        (fixture / "react-reset.png").write_bytes(base64.b64decode(screenshot["data"]))
        exceptions = [e for e in events if e.get("method") == "Runtime.exceptionThrown"]
        assert not exceptions, exceptions
        return {"result": "pass", "browser": version["Browser"], "checks": ["keyboard login/registration tab switching", "password-only login", "no phantom examples", "image choose/remove/send/persist/resend with native provider pixels",
                "empty-chat durable resume through actual React composer", "protobuf in Project memory", "separate light/dark PDF routes",
                "create a fresh project in the production UI", "specify server through composer with real Lean compilation", "generated Grammar, interaction, state and CTL views",
                "independent human acceptance of checked requirements and implementation", "actual source files and sandboxed Go test after both gates", "no uncaught browser exceptions"]}
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
