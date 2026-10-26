#!/usr/bin/env python3
"""Refs: leanfm.application_launch; native launch and malicious-preview isolation.
Uses a disposable replica of the checked GoServer inputs and keyless test
sessions in a separate real Lean server. No live account or provider is used.
"""
import sys
sys.dont_write_bytecode=True
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import websocket
from chatui_application import check_resources

ROOT=Path(__file__).resolve().parents[1]
REPORT=ROOT/'reports/application-launch-review'
TOKEN='a'*64
OTHER='b'*64


def main():
    screenshots='--screenshots' in sys.argv
    provider=None
    if screenshots:
        class DocumentationProvider(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def send_json(self,value):
                body=json.dumps(value).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
            def do_GET(self): self.send_json({'object':'list','data':[{'id':'documentation-model','object':'model','owned_by':'local-fixture'}]})
            def do_POST(self):
                self.server.requests_started+=1
                self.rfile.read(int(self.headers.get('Content-Length','0')))
                time.sleep(5)
                self.send_json({'id':'documentation-response','object':'response','status':'completed','model':'documentation-model','output':[{'type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'A room is created by CreateRoom, followed by RoomCreated or RequestRejected. Open Tasks and choose Create a named chat room, then States to inspect the generated state machine. Project memory shows whether the requirements and implementation are checked and committed. This reply comes from the local documentation fixture.'}]}],'usage':{'input_tokens':80,'output_tokens':32,'total_tokens':112,'input_tokens_details':{'cached_tokens':0}}})
        provider=ThreadingHTTPServer(('127.0.0.1',0),DocumentationProvider)
        provider.requests_started=0
        threading.Thread(target=provider.serve_forever,daemon=True).start()
    fixture=Path(tempfile.mkdtemp(prefix='application-check-',dir=ROOT/'.cache'))
    workspace=fixture/'workspace'; workspace.mkdir()
    project=workspace/'projects/GoServer'; project.mkdir(parents=True)
    original=ROOT/'projects/GoServer'
    for name in ['source','spec','book']:
        shutil.copytree(original/name,project/name,ignore=shutil.ignore_patterns('__pycache__','*.log','*.aux','*.out','*.toc'))
    shutil.copy2(original/'manifest.json',project/'manifest.json')
    shutil.copytree(original/'reports/specification-check',project/'reports/specification-check')
    project_id=json.loads((project/'manifest.json').read_text())['project_id']
    listener=socket.socket(); listener.bind(('127.0.0.1',0)); port=listener.getsockname()[1]; listener.close()
    base='http://127.0.0.1:'+str(port)
    appbase='/api/projects/'+project_id+'/application'
    # Fixture-only hostile backend probe: its source remains below the fixture root.
    path=project/'source/cmd/demo/main.go'
    source=path.read_text()
    probe='''
    mux.HandleFunc("/isolation-probe", func(w http.ResponseWriter, r *http.Request) {
        _, outsideErr := os.ReadFile("HOST_SENTINEL")
        sourceErr := os.WriteFile("/work/source/forbidden-write", []byte("x"), 0600)
        connection, networkErr := net.DialTimeout("tcp", "HOST_ENDPOINT", 100*time.Millisecond)
        if connection != nil { connection.Close() }
        writeJSON(w, map[string]any{"outsideDenied":outsideErr!=nil,"sourceReadOnly":sourceErr!=nil,"hostNetworkDenied":networkErr!=nil,"cookieAbsent":r.Header.Get("Cookie")=="","authorizationAbsent":r.Header.Get("Authorization")==""})
    })
'''.replace('HOST_SENTINEL',str(workspace/'.leanfm/host-sentinel')).replace('HOST_ENDPOINT','127.0.0.1:'+str(port))
    source=source.replace('mux := http.NewServeMux()','mux := http.NewServeMux()'+probe,1)
    path.write_text(source)
    (workspace/'.leanfm').mkdir(); (workspace/'.leanfm/host-sentinel').write_text('fixture-private-sentinel')
    driver=fixture/'ServerFixture.lean'
    driver.write_text('''import Server
open LeanFM.ChatUI.Store
def serveLauncherFixture : IO Unit := do
  let root ← workspaceRoot
  unless root.contains "/.cache/application-check-" do throw (IO.userError "Fixture must be disposable")
  let now ← IO.monoMsNow
  unlockedSessions.set ([('''+json.dumps(TOKEN)+''', "fixture"), ('''+json.dumps(OTHER)+''', "other")].map fun (token, username) =>
    {token, username, apiKey := "", provider := "openai", credentialRef := "fixture", credentialFingerprint := "fixture",
     tokensUsed := 0, tokenBudget := 1000, expiresAt := now+3600000, credentials := []})
  LeanFM.Server.main

#eval serveLauncherFixture
''')
    if screenshots:
        body=driver.read_text().replace('apiKey := "", provider', 'apiKey := "documentation-placeholder", provider')
        body=body.replace('credentials := []', 'credentials := [{provider := "openai", credentialRef := "fixture", apiKey := "documentation-placeholder", fingerprint := "fixture"}]')
        driver.write_text(body)
    env=dict(os.environ,LEANFM_WORKSPACE_ROOT=str(workspace),LEANFM_PORT=str(port),LEANFM_OPENAI_BASE_URL='http://127.0.0.1:1',LEANFM_ANTHROPIC_BASE_URL='http://127.0.0.1:1',LEANFM_TEST_SECRET='must-not-enter-app')
    if screenshots:
        env.update(LEANFM_OPENAI_BASE_URL='http://127.0.0.1:'+str(provider.server_address[1])+'/v1',LEANFM_LLM_MODEL='documentation-model')
    log=(fixture/'server.log').open('w')
    server=subprocess.Popen(['lake','env','lean',str(driver)],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
    chrome=None; connection=None
    def request(path,method='GET',body=None,token=TOKEN,headers=None):
        data=None if body is None else json.dumps(body).encode()
        values={'X-LeanFM-Request-ID':secrets.token_hex(12)}
        if token: values['Cookie']='leanfm_session_'+str(port)+'='+token
        if data is not None: values['Content-Type']='application/json'
        values.update(headers or {})
        req=urllib.request.Request(base+path,data=data,method=method,headers=values)
        try:
            with urllib.request.urlopen(req,timeout=100) as response: return response.status,response.read(),dict(response.headers)
        except urllib.error.HTTPError as error: return error.code,error.read(),dict(error.headers)
    try:
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            if server.poll() is not None: raise AssertionError((fixture/'server.log').read_text()[-4000:])
            try:
                if request('/health',token='')[0]==200: break
            except OSError: time.sleep(.1)
        else: raise AssertionError('Fixture server did not start')
        code,me,_=request('/api/me')
        assert code==200 and json.loads(me).get('username')=='fixture', (code,me)
        assert request(appbase,token='')[0]==401
        assert request(appbase+'/start','POST',{},token='')[0]==401
        profile=fixture/'chrome-profile'
        chrome_log=(fixture/'chrome.log').open('w')
        chrome=subprocess.Popen(['google-chrome','--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--disable-background-networking','--no-first-run','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--remote-allow-origins=http://127.0.0.1','--user-data-dir='+str(profile),'about:blank'],stdout=chrome_log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+15
        while not (profile/'DevToolsActivePort').exists() and time.monotonic()<deadline: time.sleep(.05)
        debug_port=(profile/'DevToolsActivePort').read_text().splitlines()[0]
        with urllib.request.urlopen('http://127.0.0.1:'+debug_port+'/json/version') as response: info=json.load(response)
        connection=websocket.create_connection(info['webSocketDebuggerUrl'],origin='http://127.0.0.1',timeout=110)
        sequence=0
        def call(method,params=None,session=None):
            nonlocal sequence
            sequence+=1; payload={'id':sequence,'method':method,'params':params or {}}
            if session: payload['sessionId']=session
            connection.send(json.dumps(payload))
            while True:
                response=json.loads(connection.recv())
                if response.get('id')==sequence:
                    if 'error' in response: raise AssertionError(response['error'])
                    return response.get('result',{})
        def tab(url):
            target=call('Target.createTarget',{'url':'about:blank'})['targetId']
            session=call('Target.attachToTarget',{'targetId':target,'flatten':True})['sessionId']
            call('Network.enable',session=session)
            call('Network.setCookie',{'name':'leanfm_session_'+str(port),'value':TOKEN,'url':base,'httpOnly':True,'sameSite':'Strict'},session)
            call('Page.enable',session=session)
            call('Runtime.enable',session=session)
            call('Page.navigate',{'url':url},session)
            return session
        def evaluate(session,expression):
            value=call('Runtime.evaluate',{'expression':expression,'awaitPromise':True,'returnByValue':True},session)
            if 'exceptionDetails' in value: raise AssertionError(value['exceptionDetails'].get('text','JavaScript exception'))
            return value.get('result',{}).get('value')
        def wait(session,expression,seconds=15):
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                if evaluate(session,expression): return
                if '.application-controls a' in expression:
                    issue=evaluate(session,"document.querySelector('.application-controls .error')?.textContent || ''")
                    if issue: raise AssertionError('Native launch failed: '+issue)
                time.sleep(.1)
            detail=evaluate(session,"document.querySelector('.application-controls')?.textContent || document.body.innerText.slice(-1200)")
            raise AssertionError('Browser timed out: '+expression+'; '+str(detail))
        ui=tab(base+'/')
        wait(ui,"!!document.querySelector('.application-controls')")
        tour=None
        if screenshots:
            from chatui_ui_tour import Tour
            tour=Tour(call,evaluate,wait,request,fixture,project_id)
            tour.viewport(ui)
            anonymous_context=call('Target.createBrowserContext')['browserContextId']
            target=call('Target.createTarget',{'url':'about:blank','browserContextId':anonymous_context})['targetId']
            anonymous=call('Target.attachToTarget',{'targetId':target,'flatten':True})['sessionId']
            call('Page.enable',session=anonymous); tour.viewport(anonymous)
            call('Target.activateTarget',{'targetId':target})
            call('Page.navigate',{'url':base+'/'},anonymous)
            wait(anonymous,"!!document.querySelector('.session-controls')")
            if not evaluate(anonymous,"!!document.querySelector('dialog[open]')"): tour.activate(anonymous,'.session-controls button','Sign in')
            wait(anonymous,"!!document.querySelector('dialog[open]')")
            tour.capture(anonymous,'01-sign-in','Before LoginSubmitted','Where do I unlock my saved keys with the LeanFM password?')
            tour.activate(anonymous,'dialog button[role=tab]','Create account')
            tour.capture(anonymous,'02-create-account','Before AccountCreateSubmitted','Which fields create an account and add provider keys?')
            call('Target.disposeBrowserContext',{'browserContextId':anonymous_context})
            call('Target.activateTarget',{'targetId':next(t['targetId'] for t in call('Target.getTargets')['targetInfos'] if t['url']==base+'/')})
            tour.capture(ui,'03-chat-ready','Project opened; before ChatPromptSubmitted','Where are the project selector, model selector and composer?')
            tour.type(ui,'.composer textarea','Which messages create a room, and how can I review their states?')
            tour.activate(ui,'.composer button','Send')
            wait(ui,"!!document.querySelector('.workspace-agent-running')")
            deadline=time.monotonic()+5
            while not provider.requests_started and time.monotonic()<deadline: time.sleep(.05)
            assert provider.requests_started, 'Provider request event was not observed'
            assert evaluate(ui,"!document.querySelector('.workspace-agent-running small').textContent.includes('No agent turn is active')"), 'Stale idle status replaced the active turn'
            wait(ui,"document.querySelector('.workspace-agent-running small').textContent.includes('waiting for documentation-model')",5)
            tour.capture(ui,'04-chat-running','ChatPromptSubmitted and ModelRequestIssued; before ModelResponseReturned','How do I see the active model, progress, elapsed time and Cancel control?')
            wait(ui,"!document.querySelector('.workspace-agent-running')",30)
            wait(ui,"document.querySelector('.messages').textContent.includes('local documentation fixture')")
            tour.capture(ui,'05-chat-response','After ChatResponseRendered','Where are the reply, usage, Resend and Delete controls?')
            tour.activate(ui,'.phase-tabs button','Project memory')
            wait(ui,"!!document.querySelector('.memory-workbench')")
            tour.capture(ui,'06-project-memory','Both actual checked specification revisions loaded','Where do I review durable files and their check and git status?')
            tour.activate(ui,'.phase-tabs button','Book')
            wait(ui,"!!document.querySelector('#bookSource') && document.querySelector('#bookSource').value.length>100")
            time.sleep(1)
            tour.capture(ui,'07-book','Saved book source and its built PDF opened','How do I read, edit, build and switch the book PDFs?')
            tour.activate(ui,'.phase-tabs button','Tasks')
            wait(ui,"!!document.querySelector('.diagram-task')")
            tour.activate(ui,'.diagram-task','Create a named chat room',True)
            tour.activate(ui,'.diagram-kind button','States · state machine')
            wait(ui,"!!document.querySelector('.diagram-stage svg')")
            tour.capture(ui,'08-task-states','Current create_room task rendered from its checked typed specification','Where is the generated state machine and how do I switch behavioral views?')
            tour.activate(ui,'.phase-tabs button','Source')
            wait(ui,"!!document.querySelector('.source-view pre')")
            tour.capture(ui,'09-source','Implementation source inventory opened','How do I inspect the actual source and its tests?')
            tour.activate(ui,'.phase-tabs button','Chat')
        launch_provider_count=provider.requests_started if provider else 0
        evaluate(ui,"document.querySelector('.application-controls button').click()")
        wait(ui,"!!document.querySelector('.application-controls a')",100)
        assert evaluate(ui,"document.querySelector('.application-controls a').getAttribute('href')")==appbase+'/open'
        wait(ui,"document.querySelector('.messages').textContent.includes('Application is running.')")
        wait(ui,"!!document.querySelector('.messages a.application-chat-link')")
        if tour: tour.capture(ui,'10-app-ready','ApplicationReady; native Open app link posted in chat','How do I start the app and open the verified running preview?')
        status_code,raw,_=request(appbase)
        state=json.loads(raw); assert status_code==200 and state['state']=='running' and state['request_id']
        with ThreadPoolExecutor(2) as pool:
            duplicates=list(pool.map(lambda _:request(appbase+'/start','POST',{}),range(2)))
        assert all(json.loads(item[1])['instance_id']==state['instance_id'] for item in duplicates)
        if provider: assert provider.requests_started==launch_provider_count, 'Native launch invoked the model'
        assert request(appbase,token=OTHER)[0]>=400
        assert request(appbase+'/stop','POST',{'instance_id':'forged'})[0]>=400
        assert json.loads(request(appbase)[1])['state']=='running'
        code,html,wrapper_headers=request(appbase+'/open')
        assert code==200 and b'sandbox="allow-scripts allow-forms"' in html
        preview=html.decode().split('src="',1)[1].split('"',1)[0]
        assert TOKEN not in preview and '127.0.0.1' not in state['url']
        code,probe_raw,headers=request(preview+'isolation-probe',headers={'Authorization':'must-not-enter-app'})
        assert code==200,probe_raw
        assert all(json.loads(probe_raw).values()),probe_raw
        assert 'sandbox allow-scripts allow-forms' in headers['Content-Security-Policy']
        assert 'allow-same-origin' not in headers['Content-Security-Policy']
        assert request(preview.replace(preview.split('/')[-2],'0'*64)+'health')[0]>=400
        assert request(preview+'%2e%2e/api/me')[0]>=400
        assert request(preview+'api/list_rooms','OPTIONS',headers={'Origin':'null','Access-Control-Request-Method':'POST','Access-Control-Request-Headers':'Content-Type'})[0]==204
        wrapper=tab(base+appbase+'/open')
        wait(wrapper,"!!document.querySelector('iframe[sandbox]')")
        time.sleep(.5)
        # Chrome may put an opaque sandbox in a separate iframe target (OOPIF).
        targets=call('Target.getTargets')['targetInfos']
        child=next((target for target in targets if target['type']=='iframe' and target['url']==base+preview),None)
        if child:
            child_session=call('Target.attachToTarget',{'targetId':child['targetId'],'flatten':True})['sessionId']
            call('Runtime.enable',session=child_session)
            wait(child_session,"document.title==='GoServer · Rooms and challenges'")
        else:
            frame_tree=call('Page.getFrameTree',session=wrapper)['frameTree']
            if not frame_tree.get('childFrames'):
                shot=call('Page.captureScreenshot',{'format':'png'},wrapper)
                (fixture/'wrapper-failure.png').write_bytes(base64.b64decode(shot['data']))
                raise AssertionError('No app frame or isolated iframe target; target types: '+str([t['type'] for t in targets]))
            child_frame=frame_tree['childFrames'][0]['frame']['id']
            world=call('Page.createIsolatedWorld',{'frameId':child_frame,'worldName':'launcher-verification'},wrapper)['executionContextId']
            observed=call('Runtime.evaluate',{'expression':"document.title==='GoServer · Rooms and challenges'",'contextId':world,'returnByValue':True},wrapper)
            assert observed.get('result',{}).get('value'), 'The actual sandboxed iframe did not render the app'
        app=tab(base+preview)
        wait(app,"typeof openRoom==='function'")
        assert evaluate(app,"(()=>{try{document.cookie;return false}catch{return true}})()")
        assert evaluate(app,"(()=>{try{localStorage.getItem('x');return false}catch{return true}})()")
        assert evaluate(app,"fetch('/api/me',{credentials:'include'}).then(()=>false,()=>true)")
        evaluate(app,"document.getElementById('identity').value='preview-player';document.getElementById('session-form').requestSubmit()")
        wait(app,"document.getElementById('room-state').textContent==='Joined'")
        evaluate(app,"document.getElementById('room-name').value='Preview room';document.getElementById('room-form').requestSubmit()")
        wait(app,"document.getElementById('room-heading').textContent==='Preview room' && document.getElementById('room-state').textContent==='Joined'")
        evaluate(app,"document.getElementById('challenge-name').value='Preview challenge';document.getElementById('challenge-form').requestSubmit()")
        wait(app,"document.getElementById('game-heading').textContent==='Preview challenge' && !document.getElementById('game-chat-fields').disabled")
        evaluate(app,"document.getElementById('game-message').value='hello through the preview';document.getElementById('game-chat-form').requestSubmit()")
        wait(app,"document.getElementById('game-chat').textContent.includes('hello through the preview')")
        shot=call('Page.captureScreenshot',{'format':'png'},app)
        (REPORT/'preview.png').write_bytes(base64.b64decode(shot['data']))
        if tour:
            tour.viewport(app)
            tour.capture(app,'11-app-preview','RoomCreated, GameCreated and GameChat observed through the isolated preview','What does the built GoServer room and challenge flow look like?')
            tour.finish()
        # No receipt can keep an old source revision current.
        asset=project/'source/cmd/demo/static/app.js'; original_asset=asset.read_text(); asset.write_text(original_asset+'\n// changed fixture revision\n')
        assert json.loads(request(appbase)[1])['state']=='stale'
        assert request(preview+'health')[0]>=400
        asset.write_text(original_asset)
        assert request(appbase+'/stop','POST',{'instance_id':state['instance_id']})[0]==200
        assert json.loads(request(appbase)[1])['state']=='stopped'
        assert request(preview+'health')[0]>=400
        assert request(appbase+'/stop','POST',{})[0]==200
        # A missing uniform target fails inside the worker, never on the host.
        makefile=project/'source/Makefile'; original_make=makefile.read_text()
        makefile.write_text(original_make.replace('serve: run',''))
        code,body,_=request(appbase+'/start','POST',{})
        assert code>=400 and b'make serve' in body,(code,body)
        makefile.write_text(original_make)
        # Enforce aggregate cache bounds without allocating large physical files.
        quota=fixture/'quota'; quota.mkdir()
        with (quota/'large').open('wb') as output: output.truncate(513*1024**2)
        try: check_resources(os.getpid(),quota)
        except ValueError: pass
        else: raise AssertionError('Cache budget was not enforced')
        subprocess.run(['protoc','-I',str(ROOT/'LeanFM/LLMGenerated'),'--python_out='+str(fixture),str(ROOT/'LeanFM/LLMGenerated/ApplicationLaunch.proto')],check=True,capture_output=True)
        sys.path.insert(0,str(fixture))
        import ApplicationLaunch_pb2 as wire
        events=[json.loads(line) for line in (project/'.leanfm/application/events.jsonl').read_text().splitlines()]
        assert events and len(events)%2==0
        for index in range(0,len(events),2):
            request_event,response_event=events[index:index+2]
            assert response_event['cause_id']==request_event['id']
            assert response_event['session']==request_event['session'] and response_event['task']==request_event['task']
            assert response_event['payload']['request_id']==request_event['payload']['request_id']
            legal={'ApplicationStartRequested':{'ApplicationReady','ApplicationLaunchRejected'},'ApplicationStatusRequested':{'ApplicationStatusReturned'},'ApplicationStopRequested':{'ApplicationStopped','ApplicationStopRejected'}}
            assert response_event['message'] in legal[request_event['message']]
            for event in [request_event,response_event]:
                message=getattr(wire,event['message'])(**event['payload'])
                assert type(message).FromString(message.SerializeToString(deterministic=True))==message
        assert TOKEN not in (project/'.leanfm/application/events.jsonl').read_text()
        (REPORT/'native-validation.json').write_text(json.dumps({'status':'passed','fixture':str(fixture.relative_to(ROOT)), 'runtime_revision':state['revision'], 'fixture_host_port':port, 'launcher_source_sha256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['scripts/chatui_application.py','scripts/chatui_application_test.py','LeanFM/ChatUI/Server.lean','Server.lean','ui/src/main.tsx']}, 'application_source_sha256':{str(path.relative_to(project)):hashlib.sha256(path.read_bytes()).hexdigest() for path in (project/'source').rglob('*') if path.is_file()}, 'checks':['native UI start and served Open app link','launch link posted in chat without provider I/O','duplicate concurrent start reuses instance','authentication and runtime owner checks','forged stop leaves live instance alone','private filesystem/read-only source/host-network isolation','engineering cookies and authorization stripped','opaque browser cookies/storage blocked','engineering API fetch blocked by preview policy','relative assets and room/challenge/chat API through served preview','CORS preflight scoped to capability','forged capability and traversal denied','source revision invalidates preview','idempotent owned stop','missing uniform target rejected','aggregate cache admission enforced','observed lifecycle protobuf byte round trips and causal grammar pairs'],'screenshot':'reports/application-launch-review/preview.png'},indent=2)+'\n')
        print('ok: native launcher, real preview room/challenge/chat, isolation and negative lifecycle checks')
    finally:
        try: request(appbase+'/stop','POST',{})
        except Exception: pass
        if connection: connection.close()
        if chrome:
            chrome.terminate()
            try: chrome.wait(timeout=5)
            except subprocess.TimeoutExpired: chrome.kill(); chrome.wait()
        server.terminate()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
        log.close()
        if provider: provider.shutdown(); provider.server_close()
        print('Fixture retained at '+str(fixture.relative_to(ROOT)))

if __name__=='__main__': main()
