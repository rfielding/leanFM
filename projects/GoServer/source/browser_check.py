#!/usr/bin/env python3
"""Requirement refs: Browser navigation reflects server state; Browser never fabricates destinations or crosses scopes.
Real Chrome verification of the local inspection browser; uses existing websocket-client.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import urllib.request
import websocket

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'reports/browser'
PROFILE = ROOT / '.cache/rooms-browser-profile'
BASE = 'http://127.0.0.1:8081'

def main():
    REPORT.mkdir(parents=True, exist_ok=True)
    server_log = (REPORT / 'browser-app.log').open('w')
    chrome_log = (REPORT / 'chrome.log').open('w')
    server = subprocess.Popen(['make', 'run'], cwd=ROOT/'source', stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
    chrome = None
    connection = None
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if server.poll() is not None: raise AssertionError('make run exited: ' + (REPORT/'browser-app.log').read_text()[-2000:])
            try:
                with urllib.request.urlopen(BASE + '/health', timeout=.5) as response:
                    if response.status == 200: break
            except OSError: time.sleep(.1)
        else: raise AssertionError('App did not become ready')
        (PROFILE/'DevToolsActivePort').unlink(missing_ok=True)
        chrome = subprocess.Popen([os.environ.get('CHROME', 'google-chrome'),'--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--disable-background-networking','--no-first-run','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--remote-allow-origins=http://127.0.0.1','--user-data-dir='+str(PROFILE),'--crash-dumps-dir='+str(PROFILE/'crashes'),'about:blank'], stdout=chrome_log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while not (PROFILE/'DevToolsActivePort').exists() and time.monotonic() < deadline:
            if chrome.poll() is not None: raise AssertionError('Chrome exited')
            time.sleep(.05)
        port = (PROFILE/'DevToolsActivePort').read_text().splitlines()[0]
        with urllib.request.urlopen('http://127.0.0.1:'+port+'/json/version') as response: info=json.load(response)
        connection = websocket.create_connection(info['webSocketDebuggerUrl'],origin='http://127.0.0.1',timeout=20)
        sequence = 0
        errors = []
        def call(method, params=None, session=None):
            nonlocal sequence
            sequence += 1
            request={'id':sequence,'method':method,'params':params or {}}
            if session: request['sessionId']=session
            connection.send(json.dumps(request))
            while True:
                result=json.loads(connection.recv())
                if result.get('method')=='Runtime.exceptionThrown': errors.append(result['params']['exceptionDetails'].get('text','browser exception'))
                if result.get('id')==sequence:
                    if 'error' in result: raise AssertionError(result['error'])
                    return result.get('result',{})
        def tab():
            context=call('Target.createBrowserContext')['browserContextId']
            target=call('Target.createTarget',{'url':'about:blank','browserContextId':context})['targetId']
            session=call('Target.attachToTarget',{'targetId':target,'flatten':True})['sessionId']
            call('Runtime.enable',session=session)
            call('Page.enable',session=session)
            call('Emulation.setDeviceMetricsOverride',{'width':1400,'height':1100,'deviceScaleFactor':1,'mobile':False},session)
            call('Page.navigate',{'url':BASE},session)
            return session
        def evaluate(session, expression):
            result=call('Runtime.evaluate',{'expression':expression,'awaitPromise':True,'returnByValue':True},session)
            if 'exceptionDetails' in result: raise AssertionError(result['exceptionDetails'].get('text','JavaScript exception'))
            return result.get('result',{}).get('value')
        def wait(session, expression, seconds=12):
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                if evaluate(session,expression): return
                time.sleep(.05)
            raise AssertionError('Browser condition timed out: '+expression)
        def form(session, field, value, form_id):
            evaluate(session,'document.getElementById('+json.dumps(field)+').value='+json.dumps(value)+';document.getElementById('+json.dumps(form_id)+').requestSubmit()')
        alice=tab(); wait(alice,"typeof openRoom==='function'")
        form(alice,'identity','browser-alice','session-form')
        wait(alice,"document.getElementById('room-state').textContent==='Joined'")
        room='Study room <b>literal</b>'
        game='Evening game <img src=x onerror=window.injected=true>'
        form(alice,'room-name',room,'room-form')
        wait(alice,"document.getElementById('room-heading').textContent==="+json.dumps(room)+" && document.getElementById('room-state').textContent==='Joined'")
        form(alice,'challenge-name',game,'challenge-form')
        wait(alice,"document.getElementById('game-heading').textContent==="+json.dumps(game)+" && !document.getElementById('game-chat-fields').disabled")
        form(alice,'room-message','room secret','room-chat-form')
        wait(alice,"document.getElementById('room-chat').textContent.includes('room secret')")
        form(alice,'game-message','game secret','game-chat-form')
        wait(alice,"document.getElementById('game-chat').textContent.includes('game secret')")
        assert evaluate(alice,"!document.getElementById('room-chat').textContent.includes('game secret') && !document.getElementById('game-chat').textContent.includes('room secret')")
        assert evaluate(alice,"!window.injected && !document.querySelector('.workspace img,.workspace b')")
        assert evaluate(alice,"!document.body.innerText.includes(sessionStorage.getItem('goserver:session')) && !document.querySelector('a[href=\"#\"]')")
        bob=tab(); wait(bob,"typeof openRoom==='function'")
        form(bob,'identity','browser-bob','session-form'); wait(bob,"document.getElementById('room-state').textContent==='Joined'")
        assert evaluate(bob,"!document.getElementById('room-chat').textContent.includes('room secret')")
        assert evaluate(bob,"(async()=>{const r=await fetch('./api/room_history',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:sessionStorage.getItem('goserver:session'),roomId:"+json.dumps(room)+"})});return r.status===403 && !(await r.text()).includes('room secret')})()")
        wait(bob,"Array.from(document.querySelectorAll('.room-button')).some(b=>b.dataset.room==="+json.dumps(room)+")")
        evaluate(bob,"Array.from(document.querySelectorAll('.room-button')).find(b=>b.dataset.room==="+json.dumps(room)+").click()")
        wait(bob,"document.getElementById('room-chat').textContent.includes('room secret')")
        wait(bob,"!!document.querySelector('.challenge-card button')")
        evaluate(bob,"document.querySelector('.challenge-card button').click()")
        wait(bob,"!document.getElementById('game-chat-fields').disabled")
        form(bob,'game-message','bob game','game-chat-form')
        wait(alice,"document.getElementById('game-chat').textContent.includes('bob game')")
        # Hold an old-scope HTTP response, switch rooms and release it afterwards.
        evaluate(alice,"window.originalFetch=window.fetch;window.holdOld=true;window.fetch=async(...args)=>{const response=await window.originalFetch(...args);if(window.holdOld&&args[0].endsWith('room_history')){window.holdOld=false;await new Promise(resolve=>window.releaseOld=resolve)}return response};void refreshRoom()")
        wait(alice,"typeof window.releaseOld==='function'")
        evaluate(alice,"void openRoom('lobby')")
        wait(alice,"document.getElementById('room-heading').textContent==='lobby' && document.getElementById('room-state').textContent==='Joined'")
        evaluate(alice,"window.releaseOld();window.fetch=window.originalFetch")
        time.sleep(.2)
        assert evaluate(alice,"!document.getElementById('room-chat').textContent.includes('room secret') && document.getElementById('game-panel').hidden && !document.getElementById('challenge-list').textContent.includes('Evening game')")
        evaluate(alice,'void openRoom('+json.dumps(room)+')')
        wait(alice,"!!document.querySelector('.challenge-card button')")
        evaluate(alice,"document.querySelector('.challenge-card button').click()")
        wait(alice,"document.getElementById('game-chat').textContent.includes('bob game')")
        shot=call('Page.captureScreenshot',{'format':'png','captureBeyondViewport':True},alice)
        (REPORT/'browser.png').write_bytes(base64.b64decode(shot['data']))
        assert not errors, errors
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'source').rglob('*') if p.is_file()}
        report={'status':'passed','checks':['real make run readiness','named room creation','named challenge creation/open','two-user room and game chat','membership rejection before room entry','literal markup rendering','no displayed session token or placeholder link','delayed old-scope response rejected','no uncaught browser errors'],'source_sha256':source_hashes,'screenshot':'reports/browser/browser.png'}
        (REPORT/'browser-validation.json').write_text(json.dumps(report,indent=2)+'\n')
        print('ok: real Chrome room/challenge/chat flow, isolation, literal text and stale-response checks')
    finally:
        if connection: connection.close()
        if chrome:
            chrome.terminate()
            try: chrome.wait(timeout=5)
            except subprocess.TimeoutExpired: chrome.kill(); chrome.wait()
        if server.poll() is None:
            stopped=subprocess.run(['make','stop'],cwd=ROOT/'source',capture_output=True,text=True)
            if stopped.returncode: print(stopped.stdout+stopped.stderr)
            try: server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid,signal.SIGTERM)
                server.wait(timeout=5)
        server_log.close(); chrome_log.close()

if __name__=='__main__': main()
