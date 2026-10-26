#!/usr/bin/env python3
"""Refs: leanfm.application_launch; persistent owned applications and opaque previews.
All project state is below its root. The short-lived CLI never runs app Makefiles
on the host; a persistent owned supervisor manages a private bubblewrap worker.
"""
import sys
sys.dont_write_bytecode = True
import base64
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import resource
import secrets
import signal
import shutil
import socket
import socketserver
import subprocess
import threading
import time
from urllib.parse import unquote, urlsplit
from chatui_specification import atomic, confined
from chatui_runtime import contract, revision

INSTALLATION = Path(__file__).resolve().parents[1]
LIMIT = 4 * 1024 * 1024
TARGETS = ('build', 'run', 'stop', 'test', 'check', 'clean', 'serve')


def directory(root):
    value=confined(root, '.leanfm/application', directory=True)
    value.chmod(0o700)
    return value


def record(root):
    path = confined(root, '.leanfm/application/state.json')
    if not path.exists():
        return {}
    if path.stat().st_size > 16384:
        raise ValueError('Invalid runtime record')
    value=json.loads(path.read_text())
    if value.get('root') != str(root): return {} # A copied root cannot control its original runtime.
    return value


def write_record(root, data):
    directory(root)
    atomic(confined(root, '.leanfm/application/state.json'), json.dumps(data) + '\n')


def process_time(pid):
    return Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]


def alive(data):
    try:
        pid = data['pid']
        if not isinstance(pid,int) or pid<=1: return False
        command = [part for part in Path('/proc', str(pid), 'cmdline').read_bytes().split(b'\0') if part]
        expected = [str(Path(__file__).resolve()).encode(), b'supervise', data['root'].encode(), data['instance_id'].encode()]
        return (process_time(pid) == data['start_time'] and command[1:] == expected and
                Path(command[0].decode()).resolve() == Path(sys.executable).resolve() and
                Path('/proc',str(pid),'exe').resolve() == Path(sys.executable).resolve() and
                Path('/proc', str(pid)).stat().st_uid == os.getuid())
    except (OSError, KeyError, ValueError):
        return False


def exchange(root, data, payload):
    relative = '.leanfm/application/' + data['instance_id'] + '/bridge/app.sock'
    path = confined(root, relative)
    # The socket itself is not a symlink; no supplied address is used.
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        parent_fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try: connection.connect('/proc/self/fd/'+str(parent_fd)+'/'+path.name)
        finally: os.close(parent_fd)
        connection.sendall(json.dumps(payload).encode() + b'\n')
        stream = connection.makefile('rb')
        raw = stream.readline(LIMIT * 2 + 65536)
        if not raw.endswith(b'\n'):
            raise ValueError('Oversized or incomplete application response')
        value = json.loads(raw)
        if value.get('error'):
            raise ValueError(value['error'])
        return value


def status(root, owner, project):
    data = record(root)
    if data and data.get('owner') != owner:
        raise PermissionError('This application instance belongs to another signed-in user')
    state = data.get('state', 'stopped')
    if state in {'starting', 'running'} and not alive(data):
        state = 'failed'
    if state == 'running':
        if data.get('revision') != revision(root):
            state = 'stale'
        else:
            try:
                result = exchange(root, data, {'operation':'health', 'nonce':data['nonce']})
                if not result.get('ready'):
                    state = 'failed'
            except (ValueError, OSError):
                state = 'failed'
    return {'state':state, 'project_id':project, 'instance_id':data.get('instance_id',''),
            'revision':data.get('revision',''),
            'url':('/api/projects/' + project + '/application/open') if state == 'running' else '',
            'reason':data.get('reason','') if state in {'failed','stopped'} else ''}


def stop(root, owner, instance=''):
    data = record(root)
    if not data:
        return
    if data.get('owner') != owner:
        raise PermissionError('This application instance belongs to another signed-in user')
    if instance and instance != data.get('instance_id'):
        raise ValueError('The application instance changed; refresh before stopping it')
    if alive(data):
        os.kill(data['pid'], signal.SIGTERM)
        deadline = time.monotonic() + 5
        while alive(data) and time.monotonic() < deadline:
            time.sleep(.05)
        if alive(data):
            # Recheck exact ownership and process start identity immediately before escalation.
            os.kill(data['pid'], signal.SIGKILL)
    data.update(state='stopped', reason='')
    data.pop('capability', None)
    write_record(root, data)


def worker_limits():
    # Lean 4.35 reserves ~4.5 GiB of address space (not resident memory) when importing LeanFM.
    resource.setrlimit(resource.RLIMIT_AS, (6 * 1024**3, 6 * 1024**3))
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
    resource.setrlimit(resource.RLIMIT_FSIZE, (32 * 1024**2, 32 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def check_resources(pid, cache):
    processes={}
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            try:
                fields=(entry/'stat').read_text().rsplit(')',1)[1].split()
                processes[int(entry.name)]=(int(fields[1]),int(fields[21])*os.sysconf('SC_PAGE_SIZE'))
            except (OSError,ValueError,IndexError): pass
    owned={pid}
    while True:
        found={number for number,(parent,_) in processes.items() if parent in owned}
        if found.issubset(owned): break
        owned.update(found)
    if len(owned)>256 or sum(processes.get(number,(0,0))[1] for number in owned)>512*1024**2:
        raise ValueError('Application exceeded its aggregate process or memory budget')
    total=0; entries=0
    for parent, dirs, files in os.walk(cache,followlinks=False):
        for name in dirs+files:
            entries+=1
            try: total+=(Path(parent)/name).stat(follow_symlinks=False).st_size
            except FileNotFoundError: pass
            if total>512*1024**2 or entries>10000:
                raise ValueError('Application exceeded its cache budget')


def supervise(root, instance):
    data = record(root)
    if data.get('instance_id') != instance:
        raise ValueError('Superseded application instance')
    data.update(pid=os.getpid(), start_time=process_time(os.getpid()), root=str(root))
    write_record(root, data)
    bridge = confined(root, '.leanfm/application/' + instance + '/bridge', directory=True)
    cache = confined(root, '.cache/application/' + instance, directory=True)
    prefix = ['bwrap','--die-with-parent','--new-session','--unshare-all','--uid','1000','--gid','1000','--cap-drop','ALL']
    for path in ['/usr','/bin','/lib','/lib64']:
        prefix += ['--ro-bind',path,path]
    go = INSTALLATION / '.toolchains/go'
    if go.is_dir():
        prefix += ['--ro-bind',str(go),'/go']
    prefix += ['--dir','/work','--ro-bind',str(confined(root,'source')),'/work/source',
               '--dir','/work/spec','--ro-bind',str(confined(root,'spec/runtime.json')),'/work/spec/runtime.json',
               '--bind',str(cache),'/work/.cache','--bind',str(bridge),'/bridge',
               '--ro-bind',str(INSTALLATION/'scripts'),'/runtime',
               '--proc','/proc','--dev','/dev','--size',str(128*1024**2),'--tmpfs','/tmp','--chdir','/work/source',
               '--clearenv','--setenv','HOME','/tmp','--setenv','PATH','/go/bin:/usr/bin:/bin',
               '--setenv','GOCACHE','/work/.cache/go-build','--setenv','GOMODCACHE','/work/.cache/go-mod',
               '--setenv','GOTOOLCHAIN','local','--setenv','GOPROXY','off','--setenv','GOMAXPROCS','2',
               '--setenv','PORT',str(contract(root)['port']),
               '--','/usr/bin/python3','/runtime/chatui_application.py','worker',data['nonce']]
    child = None
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        log_path = confined(root, '.leanfm/application/' + instance + '/worker.log')
        with log_path.open('wb') as log:
            child = subprocess.Popen(prefix,stdout=log,stderr=subprocess.STDOUT,preexec_fn=worker_limits)
        deadline = time.monotonic()+90
        while time.monotonic()<deadline:
            if not root.is_dir() or record(root).get('instance_id')!=instance: raise ValueError('Project or application instance was removed')
            check_resources(child.pid,cache)
            if child.poll() is not None:
                raise ValueError('Application worker exited: ' + log_path.read_text(errors='replace')[-2000:])
            if not Path('/proc',str(data['parent_pid'])).exists() or process_time(data['parent_pid']) != data['parent_start']:
                raise ValueError('LeanFM owner process ended')
            try:
                health = exchange(root,data,{'operation':'health','nonce':data['nonce']})
                if health.get('ready'):
                    break
            except (OSError,ValueError):
                time.sleep(.1)
        else:
            raise ValueError('Application readiness exceeded 90 seconds; inspect its project runtime log')
        if revision(root)!=data['revision']:
            raise ValueError('Source changed during launch; restart the current revision')
        data.update(state='running',reason='')
        write_record(root,data)
        while child.poll() is None:
            if not root.is_dir() or record(root).get('instance_id')!=instance: raise ValueError('Project or application instance was removed')
            check_resources(child.pid,cache)
            if not Path('/proc',str(data['parent_pid'])).exists() or process_time(data['parent_pid']) != data['parent_start']:
                break
            time.sleep(.2)
    except KeyboardInterrupt:
        data.update(state='stopped',reason='')
    except Exception as error:
        data.update(state='failed',reason=str(error)[:3000])
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
        if data.get('state')=='running': data.update(state='failed',reason='Application process ended')
        data.pop('capability',None)
        # Do not overwrite a newer instance.
        if record(root).get('instance_id')==instance:
            write_record(root,data)
        if cache.is_dir() and not cache.is_symlink(): shutil.rmtree(cache)


def start(root, owner, project):
    directory(root)
    with confined(root,'.leanfm/application/lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        previous = record(root)
        if previous and previous.get('owner')!=owner and alive(previous):
            raise PermissionError('Another signed-in user owns the running instance')
        observed = status(root, previous.get('owner',owner), project)
        if observed['state']=='running':
            return observed
        if previous and alive(previous):
            stop(root,owner)
        profile = contract(root)
        if not profile.get('relative_urls'):
            raise ValueError('Preview needs relative asset/API URLs; verify them and record relative_urls=true in spec/runtime.json')
        # No application Make parsing or source code executes here.
        makefile = confined(root,'source/Makefile')
        if makefile.stat().st_size>2_000_000:
            raise ValueError('Application Makefile exceeds the bounded contract')
        # Global admission is reconstructible from per-project owned records.
        admission = INSTALLATION/'.leanfm/application-admission.lock'
        admission.parent.mkdir(exist_ok=True)
        with admission.open('a') as global_lock:
            fcntl.flock(global_lock,fcntl.LOCK_EX)
            count=0
            for sibling in root.parent.iterdir():
                if sibling.is_dir() and not sibling.is_symlink():
                    try:
                        if alive(record(sibling)): count+=1
                    except (OSError,ValueError): pass
            if count>=4:
                raise ValueError('Application capacity reached: stop an existing app before starting another')
            instance = secrets.token_hex(8)
            parent_pid=os.getppid()
            # The named command boundary uses timeout as its direct parent.
            try:
                if Path('/proc',str(parent_pid),'comm').read_text().strip()=='timeout':
                    parent_pid=int(next(line.split()[1] for line in Path('/proc',str(parent_pid),'status').read_text().splitlines() if line.startswith('PPid:')))
            except OSError: pass
            data={'owner':owner,'project_id':project,'instance_id':instance,'root':str(root),
                  'nonce':secrets.token_hex(32),'capability':secrets.token_hex(32),
                  'revision':revision(root),'state':'starting','parent_pid':parent_pid,'parent_start':process_time(parent_pid)}
            write_record(root,data)
            log_path=confined(root,'.leanfm/application/supervisor.log')
            if log_path.exists() and log_path.stat().st_size>1048576: atomic(log_path,log_path.read_text(errors='replace')[-524288:])
            for entry in directory(root).iterdir():
                if entry.is_dir() and not entry.is_symlink() and re.fullmatch('[0-9a-f]{16}',entry.name): shutil.rmtree(entry)
            log=log_path.open('ab')
            child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'supervise',str(root),instance],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,close_fds=True)
            log.close()
            # Publish exact owned identity before releasing global admission.
            data.update(pid=child.pid,start_time=process_time(child.pid))
            write_record(root,data)
        deadline=time.monotonic()+92
        while time.monotonic()<deadline:
            data=record(root)
            if data.get('state')=='running':
                return status(root,owner,project)
            if data.get('state')=='failed' or not alive(data):
                raise ValueError(data.get('reason') or 'Application supervisor exited before readiness')
            time.sleep(.1)
        stop(root,owner,instance)
        raise ValueError('Application launch deadline exceeded')


def worker(nonce):
    resource.setrlimit(resource.RLIMIT_NPROC, (256, 256))
    profile=json.loads(Path('/work/spec/runtime.json').read_text())
    # All target inspection and execution occurs inside the app sandbox.
    for target in TARGETS:
        result=subprocess.run(['make','-n','-B',target],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
        if result.returncode or not result.stdout.strip() or b'Nothing to be done' in result.stdout:
            raise ValueError('Application must support make '+target+': '+result.stdout.decode(errors='replace')[-1000:])
    result=subprocess.run(['make','build'],timeout=60)
    if result.returncode: raise ValueError('make build failed')
    app=subprocess.Popen(['make','run'],start_new_session=True)
    ready=False
    permits=threading.BoundedSemaphore(32)
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            try:
                self.connection.settimeout(10)
                raw=self.rfile.readline(LIMIT*2+65536)
                if not raw.endswith(b'\n'): raise ValueError('Oversized application exchange')
                request=json.loads(raw)
                if request.get('operation')=='health':
                    if not secrets.compare_digest(str(request.get('nonce','')),nonce): raise ValueError('Invalid runtime control identity')
                    healthy=ready and app.poll() is None
                    if healthy:
                        probe=http.client.HTTPConnection('127.0.0.1',profile['port'],timeout=.5)
                        try:
                            probe.request('GET',profile['readiness_path'])
                            observed=probe.getresponse()
                            healthy=observed.status==200 and len(observed.read(65537))<=65536
                        except OSError: healthy=False
                        finally: probe.close()
                    result={'ready':healthy}
                else:
                    path=request['path']
                    parts=urlsplit(path)
                    if parts.scheme or parts.netloc or not path.startswith('/') or path.startswith('//') or any(part in {'.','..'} for part in unquote(parts.path).split('/')) or '\\' in unquote(path) or any(ord(c)<32 for c in path):
                        raise ValueError('Invalid application path')
                    body=bytes.fromhex(request.get('body_hex',''))
                    if len(body)>LIMIT: raise ValueError('Application request too large')
                    method=request['method']
                    if method not in {'GET','HEAD','POST','PUT','PATCH','DELETE'}: raise ValueError('Unsupported application method')
                    headers={}
                    content=request.get('content_type','')
                    if content:
                        if len(content)>256 or '\r' in content or '\n' in content: raise ValueError('Invalid content type')
                        headers['Content-Type']=content
                    connection=http.client.HTTPConnection('127.0.0.1',profile['port'],timeout=10)
                    try:
                        connection.request(method,path,body=body,headers=headers)
                        response=connection.getresponse()
                        payload=response.read(LIMIT+1)
                        if len(payload)>LIMIT: raise ValueError('Application response too large')
                        content_type=response.getheader('Content-Type','application/octet-stream')
                        if '\r' in content_type or '\n' in content_type or len(content_type)>256: raise ValueError('Invalid upstream content type')
                        # No cookies, authorization, redirects or upstream security headers cross the boundary.
                        if 300<=response.status<400: raise ValueError('Application redirects require relative preview-compatible routing')
                        result={'status':response.status,'content_type':content_type,'body_hex':payload.hex()}
                    finally: connection.close()
                self.wfile.write(json.dumps(result).encode()+b'\n')
            except Exception as error:
                self.wfile.write(json.dumps({'error':str(error)[:2000]}).encode()+b'\n')
    class Server(socketserver.ThreadingMixIn,socketserver.UnixStreamServer):
        daemon_threads=True
        def process_request(self, request, address):
            if not permits.acquire(blocking=False):
                request.sendall(b'{"error":"Application is busy"}\n'); self.shutdown_request(request); return
            try: super().process_request(request,address)
            except BaseException: permits.release(); raise
        def process_request_thread(self, request, address):
            try: super().process_request_thread(request,address)
            finally: permits.release()
    server=Server('/bridge/app.sock',Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        deadline=time.monotonic()+85
        while time.monotonic()<deadline:
            if app.poll() is not None: raise ValueError('make run exited before readiness')
            try:
                for path in [profile['readiness_path'],profile['page_path']]:
                    connection=http.client.HTTPConnection('127.0.0.1',profile['port'],timeout=.5)
                    try:
                        connection.request('GET',path); response=connection.getresponse(); body=response.read(LIMIT+1)
                        if response.status!=200 or not body or len(body)>LIMIT: raise OSError('Readiness or page failed')
                    finally: connection.close()
                ready=True; break
            except OSError: time.sleep(.1)
        if not ready: raise ValueError('Application readiness timed out')
        app.wait()
    finally:
        if app.poll() is None:
            os.killpg(app.pid,signal.SIGTERM)
            try: app.wait(timeout=3)
            except subprocess.TimeoutExpired: os.killpg(app.pid,signal.SIGKILL); app.wait()
        server.shutdown(); server.server_close()


CONTEXT=None

def journal(value, failed=False):
    if CONTEXT is None: return
    root,operation,payload,started,event_id=CONTEXT
    task={'start':'start_application','status':'inspect_application','stop':'stop_application'}[operation]
    request_name={'start':'ApplicationStartRequested','status':'ApplicationStatusRequested','stop':'ApplicationStopRequested'}[operation]
    response_name=({'start':'ApplicationLaunchRejected','status':'ApplicationStatusReturned','stop':'ApplicationStopRejected'} if failed else {'start':'ApplicationReady','status':'ApplicationStatusReturned','stop':'ApplicationStopped'})[operation]
    request_payload={'project_id':payload.get('project_id',''),'request_id':payload.get('request_id','')}
    if operation=='stop': request_payload['instance_id']=payload.get('instance_id','')
    allowed={'ApplicationReady':['project_id','instance_id','revision','url','request_id'],
             'ApplicationStatusReturned':['project_id','instance_id','revision','state','url','reason','request_id'],
             'ApplicationStopped':['project_id','instance_id','request_id'],
             'ApplicationLaunchRejected':['project_id','reason','request_id'],
             'ApplicationStopRejected':['project_id','reason','request_id']}[response_name]
    values=dict(value,project_id=payload.get('project_id',''),request_id=payload.get('request_id',''))
    if failed: values.update(reason=value.get('error','Application failed'),state='failed')
    response_payload={key:str(values.get(key,'')) for key in allowed}
    common={'session':payload.get('session_id',payload.get('owner','')),'task':task}
    request=dict(common,id=event_id,prior_ids=[],time_at_ms=started,src='UserBrowser',dst='LeanFMServer',message=request_name,payload=request_payload)
    response=dict(common,id=secrets.token_hex(12),prior_ids=[event_id],cause_id=event_id,time_at_ms=int(time.time()*1000),src='LeanFMServer',dst='UserBrowser',message=response_name,payload=response_payload)
    directory(root)
    with confined(root,'.leanfm/application/events.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        path=confined(root,'.leanfm/application/events.jsonl')
        old=path.read_text() if path.exists() else ''
        if len(old)>1048576: old='\n'.join(old.splitlines()[-400:])+'\n'
        atomic(path,old+json.dumps(request)+'\n'+json.dumps(response)+'\n')


def main():
    global CONTEXT
    operation=sys.argv[1]
    if operation=='worker':
        worker(sys.argv[2]); return
    root=Path(sys.argv[2])
    if root.is_symlink(): raise ValueError('Project root cannot be a symlink')
    root=root.resolve(strict=True)
    if operation=='supervise':
        supervise(root,sys.argv[3]); return
    payload=json.loads(sys.stdin.read(LIMIT*2+65536) or '{}')
    if operation in {'start','status','stop'}:
        CONTEXT=(root,operation,payload,int(time.time()*1000),secrets.token_hex(12))
    owner=payload.get('owner','')
    project=payload.get('project_id','')
    if operation=='stop' and not owner and not alive(record(root)):
        print(json.dumps({'state':'stopped','project_id':project,'instance_id':'','url':''})); return
    if operation in {'start','status','stop','open'} and not owner:
        raise PermissionError('Sign in to manage an application')
    if operation=='start':
        value=start(root,owner,project)
    elif operation=='status':
        value=status(root,owner,project)
    elif operation=='stop':
        directory(root)
        with confined(root,'.leanfm/application/lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX); stop(root,owner,payload.get('instance_id',''))
        value=status(root,owner,project)
    elif operation=='open':
        value=status(root,owner,project)
        if value['state']!='running': raise ValueError('Start the current app revision before opening it')
        data=record(root)
        value['preview_prefix']='/app-view/'+project+'/'+data['instance_id']+'/'+data['capability']+'/'
    elif operation=='proxy':
        data=record(root)
        if not data or not secrets.compare_digest(str(payload.get('capability','')),str(data.get('capability',''))) or payload.get('instance_id')!=data.get('instance_id'):
            raise PermissionError('Invalid preview capability')
        if data.get('state')!='running' or not alive(data) or revision(root)!=data.get('revision'):
            raise ValueError('Application is stopped or stale; restart it from LeanFM')
        value=({'status':204,'content_type':'text/plain','body_hex':''} if payload.get('method')=='OPTIONS' else exchange(root,data,payload))
    else: raise ValueError('Unknown application operation')
    if operation in {'start','status','stop'}: value['request_id']=payload.get('request_id','')
    journal(value)
    print(json.dumps(value))

if __name__=='__main__':
    try: main()
    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as error:
        journal({'error':str(error)[:3000]},True)
        print(json.dumps({'error':str(error)[:3000],'action':'Review the project application contract and runtime log, then retry.','code':'application_failure'}))
        raise SystemExit(1)
