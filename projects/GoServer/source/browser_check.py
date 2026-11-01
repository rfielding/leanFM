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
        A = ".room-panel:not([hidden])"            # the room tab being shown
        G = A + " .game-panel:not([hidden])"        # the game tab being shown in it
        def q(sel): return 'document.querySelector('+json.dumps(sel)+')'
        def text(sel): return '(('+q(sel)+'||{}).textContent||"")'
        def fill(session, sel, value, form_sel):
            evaluate(session, q(sel)+'.value='+json.dumps(value)+';'+q(form_sel)+'.requestSubmit()')
        def click(session, sel): evaluate(session, q(sel)+'.click()')
        def sign_in(session, name):
            wait(session, "!!"+q('.session-form'))
            fill(session, '.identity', name, '.session-form')
            wait(session, text('.room-panel[data-room="lobby"] .room-state')+"==='Joined'")
        alice=tab(); sign_in(alice,'browser-alice')
        room='Study room <b>literal</b>'
        game='Evening game <img src=x onerror=window.injected=true>'
        click(alice,'[role=tab][data-room="__rooms"]'); wait(alice,"!!"+q('.room-form'))
        fill(alice,'.room-name',room,'.room-form')
        wait(alice,text(A+' .room-heading')+"==="+json.dumps(room)+" && "+text(A+' .room-state')+"==='Joined'")
        assert evaluate(alice,"Array.from(document.querySelectorAll('.room-tabs [role=tab]')).map(t=>t.dataset.room).join('|')==='lobby|'+"+json.dumps(room)+"+'|__rooms'")
        fill(alice,A+' .challenge-form input[name=name]',game,A+' .challenge-form')
        wait(alice,text(G+' .game-heading')+"==="+json.dumps(game))
        assert evaluate(alice,"Array.from(document.querySelectorAll('"+A+" .game-tabs [role=tab]')).length===2")
        click(alice,G+' [role=tab][data-panel="chat"]'); wait(alice,"!!"+q(G+' .game-chat-form fieldset:not([disabled])'))
        fill(alice,G+' .game-chat-form input','game secret',G+' .game-chat-form')
        wait(alice,text(G+' .game-chat')+".includes('game secret')")
        click(alice,A+' [role=tab][data-game="__lobby"]'); wait(alice,"!!"+q(A+' .lobby:not([hidden]) .room-chat-form fieldset:not([disabled])'))
        fill(alice,A+' .room-chat-form input','room secret',A+' .room-chat-form')
        wait(alice,text(A+' .room-chat')+".includes('room secret')")
        assert evaluate(alice,"!"+text(A+' .room-chat')+".includes('game secret') && !"+text(A+' .game-panel .game-chat')+".includes('room secret')")
        assert evaluate(alice,"!window.injected && !document.querySelector('.room-heading b,.room-tabs b,.game-tabs img,.game-heading img,.challenge-card img,.challenge-card h3 b')")
        assert evaluate(alice,"!document.body.innerText.includes(sessionStorage.getItem('goserver:session')) && !document.querySelector('a[href=\"#\"]')")
        bob=tab(); sign_in(bob,'browser-bob')
        assert evaluate(bob,"!"+text(A+' .room-chat')+".includes('room secret')")
        assert evaluate(bob,"(async()=>{const r=await fetch('./api/room_history',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:sessionStorage.getItem('goserver:session'),roomId:"+json.dumps(room)+"})});return r.status===403 && !(await r.text()).includes('room secret')})()")
        click(bob,'[role=tab][data-room="__rooms"]')
        wait(bob,"Array.from(document.querySelectorAll('.room-button')).some(b=>b.dataset.room==="+json.dumps(room)+")")
        evaluate(bob,"Array.from(document.querySelectorAll('.room-button')).find(b=>b.dataset.room==="+json.dumps(room)+").click()")
        wait(bob,text(A+' .room-chat')+".includes('room secret')")
        wait(bob,"!!"+q(A+' .challenge-card button'))
        click(bob,A+' .challenge-card button')
        wait(bob,text(G+' .game-heading')+"==="+json.dumps(game))
        click(bob,G+' [role=tab][data-panel="chat"]'); wait(bob,"!!"+q(G+' .game-chat-form fieldset:not([disabled])'))
        fill(bob,G+' .game-chat-form input','bob game',G+' .game-chat-form')
        click(alice,A+' .game-tabs [role=tab]:not([data-game="__lobby"])')
        wait(alice,text(G+' .game-chat')+".includes('bob game')")
        # Hold an HTTP response for the study room, switch to the lobby tab, then release it:
        # the late result must land only in the study room's own tab.
        evaluate(alice,"window.originalFetch=window.fetch;window.holdOld=true;window.fetch=async(...args)=>{const response=await window.originalFetch(...args);if(window.holdOld&&String(args[0]).endsWith('room_history')&&JSON.parse(args[1].body).roomId==="+json.dumps(room)+"){window.holdOld=false;await new Promise(resolve=>window.releaseOld=resolve)}return response}")
        wait(alice,"typeof window.releaseOld==='function'", 20)
        click(alice,'[role=tab][data-room="lobby"]')
        wait(alice,text(A+' .room-heading')+"==='lobby' && "+text(A+' .room-state')+"==='Joined'")
        evaluate(alice,"window.releaseOld();window.fetch=window.originalFetch")
        time.sleep(.3)
        assert evaluate(alice,"!"+text(A+' .room-chat')+".includes('room secret') && !"+text(A+' .challenge-list')+".includes('Evening game') && "+text(A+' .room-heading')+"==='lobby'")
        click(alice,'[role=tab][data-room='+json.dumps(room)+']')
        wait(alice,text(A+' .room-heading')+"==="+json.dumps(room)+" && "+text(G+' .game-chat')+".includes('bob game')")
        shot=call('Page.captureScreenshot',{'format':'png','captureBeyondViewport':True},alice)
        (REPORT/'browser.png').write_bytes(base64.b64decode(shot['data']))
        assert not errors, errors
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'source').rglob('*') if p.is_file() and 'node_modules' not in p.parts and p.suffix != '' and 'static/app' not in str(p)}
        report={'status':'passed','checks':['real make run readiness','named room creation','named challenge creation/open','two-user room and game chat','membership rejection before room entry','literal markup rendering','no displayed session token or placeholder link','room tabs and per-room game tabs','delayed response lands only in its own room tab','no uncaught browser errors'],'source_sha256':source_hashes,'screenshot':'reports/browser/browser.png'}
        (REPORT/'browser-validation.json').write_text(json.dumps(report,indent=2)+'\n')
        print('ok: real Chrome room tabs, game tabs, room/challenge/chat flow, isolation, literal text and stale-response checks')
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
