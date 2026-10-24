#!/usr/bin/env python3
"""Real embedded React UI check; optional Chrome/websocket-client test dependency.
No imports from disposable projects, no model network and no live account use.
Requirement refs: keyless_server_has_no_provider_spend,
one_password_unlocks_all_provider_keys, selected_model_determines_provider_credential,
model_key_is_request_scoped. Exercise catalog recovery through the production UI.
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
            evaluate(f"document.querySelector({json.dumps(selector)}).focus(); document.querySelector({json.dumps(selector)}).select()")
            call("Input.insertText", {"text": text}, session)
        def click_text(text):
            evaluate(f"[...document.querySelectorAll('.project-panel:not([hidden]) button')].find(b=>b.textContent.trim()==={json.dumps(text)}).click()")
        def click_visible(selector):
            # Real pointer input catches controls hidden by responsive CSS,
            # which JavaScript element.click() does not.
            point = evaluate(f"""(() => {{
              const element = document.querySelector({json.dumps(selector)});
              element.scrollIntoView({{block: 'nearest'}});
              const box = element.getBoundingClientRect(), x = box.x + box.width / 2, y = box.y + box.height / 2;
              return {{x, y, visible: box.width > 0 && box.height > 0 && x > 0 && x < innerWidth && y > 0 && y < innerHeight && element.contains(document.elementFromPoint(x, y))}};
            }})()""")
            assert point["visible"], (selector, point)
            for kind in ["mousePressed", "mouseReleased"]:
                call("Input.dispatchMouseEvent", {"type": kind, "x": point["x"], "y": point["y"], "button": "left", "clickCount": 1}, session)

        call("Runtime.enable", session=session)
        call("Page.enable", session=session)
        # Drive the actual polling callbacks deterministically, and inject only
        # catalog transport faults. Login and all provider requests stay real.
        call("Page.addScriptToEvaluateOnNewDocument", {"source": """
          window.catalogTest = {mode: 'normal', requests: 0, held: [], polls: new Map(), chats: 0, holdChat: false, heldChat: null, logoutFailure: false};
          const originalFetch = window.fetch.bind(window);
          window.fetch = (input, init) => {
            const state = window.catalogTest;
            if (input === '/api/logout' && state.logoutFailure) return Promise.reject(new TypeError('Fixture logout connection failed'));
            if (typeof input === 'string' && input.endsWith('/chat')) {
              state.chats++;
              if (state.holdChat) {
                state.holdChat = false;
                return new Promise(resolve => { state.heldChat = () => resolve(new Response(JSON.stringify({error: 'Fixture pending chat interrupted'}), {status: 409})); });
              }
            }
            if (input !== '/api/me') return originalFetch(input, init);
            state.requests++;
            if (state.mode === 'network-error') return Promise.reject(new TypeError('Fixture model catalog connection failed'));
            if (state.mode === 'hold') return originalFetch(input, init).then(async response => {
              const body = await response.text();
              return new Promise(resolve => state.held.push(() => resolve(new Response(body, {status: response.status}))));
            });
            if (state.mode === 'empty') return originalFetch(input, init).then(async response => {
              if (!response.ok) return response;
              const body = await response.json();
              body.billing.models = []; body.billing.model_details = []; body.billing.model = '';
              return new Response(JSON.stringify(body), {status: 200});
            });
            return originalFetch(input, init);
          };
          const originalInterval = window.setInterval.bind(window), originalClear = window.clearInterval.bind(window);
          window.setInterval = (callback, delay, ...args) => {
            if (delay !== 3000) return originalInterval(callback, delay, ...args);
            const id = originalInterval(() => {}, 1000000);
            window.catalogTest.polls.set(id, () => callback(...args)); return id;
          };
          window.clearInterval = id => { window.catalogTest.polls.delete(id); originalClear(id); };
        """}, session)
        call("Emulation.setDeviceMetricsOverride", {"width": 700, "height": 900, "deviceScaleFactor": 1, "mobile": False}, session)
        call("Page.navigate", {"url": base}, session)
        wait("document.querySelector('.project-panel:not([hidden]) .model-access')?.textContent.includes('Your API keys are locked')")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer select').disabled")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer select').selectedOptions[0].textContent") == "Sign in to load models"
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_DURABLE_RESUME")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').disabled")
        assert evaluate("getComputedStyle(document.querySelector('.sidebar')).display") == "none"
        click_visible(".project-panel:not([hidden]) .session-controls button:last-child")
        wait("Boolean(document.querySelector('input[name=username]'))")
        assert not evaluate("document.querySelector('input[name=username]').readOnly")
        assert evaluate("window.catalogTest.polls.size") == 0
        assert evaluate("window.catalogTest.chats") == 0
        call("Emulation.setDeviceMetricsOverride", {"width": 1440, "height": 1100, "deviceScaleFactor": 1, "mobile": False}, session)
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
        # Polls are paused: successful unlock must refresh mounted composers
        # immediately, rather than requiring a reload or the next timer tick.
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer textarea').value") == "TEST_DURABLE_RESUME"
        assert evaluate("window.catalogTest.chats") == 0
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer select').value") == "test-model"
        assert evaluate("window.catalogTest.polls.size") == 1, "session discovery must be shared across projects"
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .session-controls span').textContent") == "reset_user"
        assert not evaluate("document.querySelector('.project-panel:not([hidden]) .model-access') !== null")
        evaluate("window.catalogTest.mode = 'network-error'; window.catalogTest.polls.forEach(refresh => refresh())")
        wait("document.querySelector('.project-panel:not([hidden]) .model-access')?.textContent.includes('Could not load your models')")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer select').disabled")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').disabled")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer textarea').value") == "TEST_DURABLE_RESUME"
        evaluate("window.catalogTest.mode = 'hold'")
        evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .model-access button')].find(b=>b.textContent==='Retry loading models').click()")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.selectedOptions[0].textContent === 'Loading models…'")
        wait("window.catalogTest.held.length >= 1")
        evaluate("window.catalogTest.mode = 'normal'; window.catalogTest.held.splice(0).forEach(release => release())")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.value === 'test-model'")
        evaluate("window.catalogTest.mode = 'empty'; window.catalogTest.polls.forEach(refresh => refresh())")
        wait("document.querySelector('.project-panel:not([hidden]) .model-access')?.textContent.includes('No models are available')")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').disabled")
        evaluate("window.catalogTest.mode = 'normal'")
        evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .model-access button')].find(b=>b.textContent==='Retry loading models').click()")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.value === 'test-model'")
        # Delayed discovery cannot overlap itself or restore a locked session.
        evaluate("window.catalogTest.mode = 'hold'; window.catalogTest.polls.forEach(refresh => refresh())")
        wait("window.catalogTest.held.length === window.catalogTest.polls.size")
        requests = evaluate("window.catalogTest.requests")
        evaluate("window.catalogTest.polls.forEach(refresh => refresh()); window.catalogTest.polls.forEach(refresh => refresh())")
        assert evaluate("window.catalogTest.requests") == requests
        click_visible(".project-panel:not([hidden]) .session-controls button:last-child")
        wait("document.querySelector('.sidebar-footer')?.textContent.includes('Keys locked')")
        evaluate("window.catalogTest.mode = 'normal'; window.catalogTest.held.splice(0).forEach(release => release())")
        wait("document.querySelector('.project-panel:not([hidden]) .model-access')?.textContent.includes('Your API keys are locked')")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer select').value") == ""
        wait("Boolean(document.querySelector('dialog[open] input[name=username]'))")
        assert evaluate("fetch('/api/me').then(response => response.status)") == 401
        assert not evaluate("document.querySelector('dialog[open] input[name=username]').readOnly")
        type_into("dialog[open] input[name=username]", "reset_user")
        type_into("dialog[open] input[name=password]", "test-reset-password")
        evaluate("document.querySelector('dialog[open] .auth form').requestSubmit()")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.value === 'test-model'")
        evaluate("window.catalogTest.logoutFailure = true")
        click_visible(".project-panel:not([hidden]) .session-controls button:last-child")
        wait("document.querySelector('.project-panel:not([hidden]) .main > .error')?.textContent.includes('Could not confirm server logout')")
        assert evaluate("window.catalogTest.polls.size") == 0
        assert evaluate("fetch('/api/me').then(response => response.status)") == 200, "failed logout must not claim server revocation"
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer select').value") == ""
        evaluate("window.catalogTest.logoutFailure = false")
        click_visible(".project-panel:not([hidden]) .session-controls button:last-child")
        wait("Boolean(document.querySelector('dialog[open] input[name=password]'))")
        assert evaluate("fetch('/api/me').then(response => response.status)") == 401
        type_into("dialog[open] input[name=password]", "test-reset-password")
        evaluate("document.querySelector('dialog[open] .auth form').requestSubmit()")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.value === 'test-model'")
        # Losing a session cookie models a server restart: no project reload,
        # no API-key re-entry, no automatic chat, and the draft survives.
        call("Network.clearBrowserCookies", session=session)
        evaluate("window.catalogTest.polls.forEach(refresh => refresh())")
        wait("document.querySelector('.project-panel:not([hidden]) .model-access')?.textContent.includes('Your API keys are locked')")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').disabled")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .session-controls span').textContent") == "Signed out"
        click_visible(".project-panel:not([hidden]) .session-controls button:last-child")
        wait("Boolean(document.querySelector('dialog[open] input[name=password]'))")
        assert not evaluate("document.querySelector('dialog[open] input[name=username]').readOnly")
        type_into("dialog[open] input[name=password]", "test-reset-password")
        evaluate("document.querySelector('dialog[open] .auth form').requestSubmit()")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.value === 'test-model'")
        assert evaluate("document.querySelector('.project-panel:not([hidden]) .composer textarea').value") == "TEST_DURABLE_RESUME"
        assert evaluate("window.catalogTest.chats") == 0
        assert "GoServer" not in evaluate("document.querySelector('.projects').textContent")
        assert "Resettable project" in evaluate("document.querySelector('.projects').textContent")
        assert "resume" in evaluate("document.querySelector('.project-panel:not([hidden]) .messages').textContent").lower()
        wait("!document.querySelector('.project-panel:not([hidden]) .composer button').disabled")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].some(m=>m.textContent.includes('Durable resume verified'))")
        evaluate("window.catalogTest.holdChat = true")
        type_into(".project-panel:not([hidden]) .composer textarea", "Fixture awaiting network")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("window.catalogTest.heldChat !== null")
        type_into(".project-panel:not([hidden]) .composer textarea", "Do not send this queued prompt after another unlock")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("document.querySelector('.project-panel:not([hidden]) .prompt-queue')?.textContent.includes('1 queued')")
        chats_before_unlock = evaluate("window.catalogTest.chats")
        call("Network.clearBrowserCookies", session=session)
        evaluate("window.catalogTest.polls.forEach(refresh => refresh())")
        wait("document.querySelector('.project-panel:not([hidden]) .model-access')?.textContent.includes('Your API keys are locked')")
        evaluate("document.querySelector('.project-panel:not([hidden]) .model-access button').click()")
        wait("Boolean(document.querySelector('dialog[open] input[name=password]'))")
        type_into("dialog[open] input[name=password]", "test-reset-password")
        evaluate("document.querySelector('dialog[open] .auth form').requestSubmit()")
        wait("document.querySelector('.project-panel:not([hidden]) .composer select')?.value === 'test-model'")
        evaluate("window.catalogTest.heldChat()")
        wait("document.querySelector('.project-panel:not([hidden]) .request-error')?.textContent.includes('Queued prompt held because the unlocked credential changed')")
        assert evaluate("window.catalogTest.chats") == chats_before_unlock
        evaluate("document.querySelector('.project-panel:not([hidden]) button[aria-label=\"Remove queued prompt 1\"]').click()")
        wait("document.querySelector('.project-panel:not([hidden]) .prompt-queue') === null")
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
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_UPDATE_BOOK")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].some(m=>m.textContent.includes('Updated the durable project book.'))")
        click_text("Book")
        click_text("Light PDF")
        wait("document.querySelector('.project-panel:not([hidden]) #bookPreview').src.includes('/main.pdf?')")
        pdf = evaluate("document.querySelector('.project-panel:not([hidden]) #bookPreview').src")
        assert evaluate(f"fetch({json.dumps(pdf)}).then(async r=>r.ok&&(await r.text()).startsWith('%PDF'))")
        click_text("Chat")
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_SPECIFY_REPAIR PDF_FIRST")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].some(m=>m.textContent.includes('Completed patch fixture'))")
        assert evaluate("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].at(-1).querySelector('.result-badge.success') !== null")
        type_into(".project-panel:not([hidden]) .composer textarea", "TEST_LONG_SPECIFICATION")
        evaluate("document.querySelector('.project-panel:not([hidden]) .composer button').click()")
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].filter(m=>m.textContent.includes('Completed patch fixture')).length === 2", seconds=60)
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
        wait("[...document.querySelectorAll('.project-panel:not([hidden]) .message.assistant')].filter(m=>m.textContent.includes('Completed patch fixture')).length === 3")
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
        return {"result": "pass", "browser": version["Browser"], "checks": ["keyboard login/registration tab switching", "password-only login", "visible locked/loading/failed/empty model states", "real mouse logout at narrow width with hidden sidebar and no session", "one shared account and model session across projects", "valid and expired logout open an editable fresh login form", "failed logout stays locally locked and retries without claiming server revocation", "immediate model refresh after unlock with polling paused", "model retry and expired-session recovery preserve drafts without sending chat", "delayed catalog responses cannot overlap or restore a locked session", "queued prompts remain held after unlocking the same key in a new session", "no phantom examples", "image choose/remove/send/persist/resend with native provider pixels",
                "empty-chat durable resume through actual React composer", "protobuf in Project memory", "separate light/dark PDF routes",
                "create a fresh project in the production UI", "chat builds a PDF before requirements authoring", "two rejected requirements candidates repair inside the original composer turn with real Lean compilation", "twenty-five model rounds complete through four-round client batches", "generated Grammar, interaction, state and CTL views",
                "independent human acceptance of checked requirements and implementation", "actual source files and sandboxed Go test after both gates", "no uncaught browser exceptions"]}
    except Exception:
        if connection:
            try:
                (fixture / "failed-react-state.json").write_text(json.dumps(evaluate("({text:document.body.innerText,html:document.body.innerHTML.slice(0,10000),catalog:{mode:window.catalogTest.mode,requests:window.catalogTest.requests,held:window.catalogTest.held.length,polls:window.catalogTest.polls.size,chats:window.catalogTest.chats}})"), indent=2))
            except Exception:
                pass
        raise
    finally:
        if connection:
            connection.close()
        chrome.terminate()
        chrome.wait(timeout=10)
        chrome_log.close()
