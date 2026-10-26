#!/usr/bin/env python3
"""Revision-bound local application launch evidence; no model-authored receipts.
Refs: runnable_application_delivery, chat_history_is_not_durable_specification,
shared_project_paths_never_reach_credentials, selfhost.pr.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from chatui_specification import atomic, confined


def contract(root):
    path = confined(root, 'spec/runtime.json')
    if not path.is_file() or path.stat().st_size > 16384:
        raise ValueError('Missing bounded spec/runtime.json: record version=1, kind=http, directory=source, command=["make","run"], host=127.0.0.1, port, readiness_path and page_path')
    value = json.loads(path.read_text())
    if (value.get('version'), value.get('kind'), value.get('directory'), value.get('command'), value.get('host')) != (1, 'http', 'source', ['make', 'run'], '127.0.0.1'):
        raise ValueError('Runtime contract requires fixed make run from source/ and loopback HTTP')
    port = value.get('port')
    reserved = int(os.environ.get('LEANFM_PORT', '8080'))
    if type(port) is not int or not 1024 <= port <= 65535 or port in {8080, reserved}:
        raise ValueError('Application port must be 1024..65535 and separate from LeanFM; use 8081 or another unused port')
    for key in ['readiness_path', 'page_path']:
        part = value.get(key)
        if not isinstance(part, str) or not part.startswith('/') or part.startswith('//') or len(part) > 256 or any(ord(c) <= 32 for c in part) or '#' in part:
            raise ValueError('Runtime probe paths must be bounded project-local URL paths')
    memory = confined(root, 'spec/ProjectMemory.md')
    if not memory.is_file() or memory.stat().st_size > 65536 or not memory.read_text().strip():
        raise ValueError('Record the original application goal, decisions and remaining gaps in bounded spec/ProjectMemory.md before completion')
    makefile = confined(root, 'source/Makefile')
    if not makefile.is_file() or makefile.stat().st_size > 2_000_000:
        raise ValueError('Application delivery needs source/Makefile with a run target')
    return value


def revision(root):
    """Hash durable inputs, ignoring disposable binaries and build caches."""
    values = []
    for relative in ['spec/runtime.json', 'book/main.tex', 'spec/Requirements.lean', 'spec/Requirements.proto', 'spec/Implementation.lean']:
        path = confined(root, relative)
        values.append([relative, hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'missing'])
    source = confined(root, 'source')
    if source.is_dir():
        for parent, directories, files in os.walk(source, followlinks=False):
            directories[:] = sorted(d for d in directories if d not in {'.cache','.git','.lake','node_modules','__pycache__'})
            for directory in directories:
                confined(root, str((Path(parent)/directory).relative_to(root)))
            for name in sorted(files):
                path = Path(parent)/name
                relative = str(path.relative_to(root))
                confined(root, relative)
                # Include text/source/config/build inputs, not an old compiled executable.
                if path.suffix or name in {'Makefile','GNUmakefile','makefile','go.mod','go.sum'}:
                    if path.stat().st_size > 4_000_000:
                        raise ValueError('Runtime input exceeds the bounded source-file limit')
                    values.append([relative,hashlib.sha256(path.read_bytes()).hexdigest()])
    return hashlib.sha256(json.dumps(values,sort_keys=True).encode()).hexdigest()


def status(root):
    try:
        profile = contract(root)
        receipt = json.loads(confined(root, 'reports/runtime-check/validation.json').read_text())
        valid = receipt.get('status') == 'validated' and receipt.get('revision') == revision(root)
        return {'valid': valid, 'reason': '' if valid else 'Runtime evidence is missing, failed or stale; use workspace_check target=run', 'url': f"http://127.0.0.1:{profile['port']}/"}
    except (OSError, ValueError, TypeError) as error:
        return {'valid': False, 'reason': str(error)}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise ValueError('Application probe redirects are not permitted')


def probe(root):
    """Runs inside the existing filesystem/process/network-isolated worker."""
    profile = contract(root)
    cache = confined(root, '.cache', directory=True)
    log_path = confined(root, '.cache/runtime-launch.log')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    url = f"http://127.0.0.1:{profile['port']}"
    child = None
    try:
        with log_path.open('wb') as log:
            child = subprocess.Popen(['make','run'], cwd=confined(root, 'source'), stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise ValueError(f'make run exited before readiness: exit_code={child.returncode}')
                try:
                    with opener.open(url + profile['readiness_path'], timeout=.5) as response:
                        body = response.read(65537)
                        if response.status != 200 or len(body) > 65536:
                            raise ValueError('Readiness response must be HTTP 200 and bounded')
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(.1)
            else:
                raise ValueError('make run did not answer readiness within 90 seconds')
            with opener.open(url + profile['page_path'], timeout=2) as response:
                page = response.read(1024*1024+1)
                if response.status != 200 or not page or len(page) > 1024*1024:
                    raise ValueError('Application page must be a nonempty bounded HTTP 200 response')
            # A successful application contract must not also bind LeanFM's port.
            for table in ['/proc/net/tcp','/proc/net/tcp6']:
                # A kernel without IPv6 has no tcp6 table and no IPv6 listeners.
                if table.endswith('6') and not Path(table).exists():
                    continue
                for line in Path(table).read_text().splitlines()[1:]:
                    fields=line.split()
                    if fields[3]=='0A':
                        address, bound_port = fields[1].rsplit(':',1)
                        if int(bound_port,16)!=profile['port'] or address!='0100007F':
                            raise ValueError('Application must listen only on its declared IPv4 loopback port, separately from LeanFM')
            if child.poll() is not None:
                raise ValueError('Application exited immediately after readiness')
            return {'status':'validated','checks':['make run remains running','readiness HTTP 200','application page HTTP 200','LeanFM port untouched'], 'url':url+'/'}
    except Exception as error:
        detail = log_path.read_text(errors='replace')[-12000:] if log_path.is_file() else ''
        raise ValueError(str(error)+'\n'+detail) from None
    finally:
        if child is not None:
            # Kill only the process group we created, including build/launch children.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=2)


def main(operation, root_name):
    root = Path(root_name).resolve(strict=True)
    if operation == 'status':
        print(json.dumps(status(root)))
    elif operation == 'probe':
        try:
            print(json.dumps(probe(root)))
        except (ValueError, OSError) as error:
            print(str(error), file=sys.stderr)
            return 1
    else:
        raise ValueError('Unknown runtime operation')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main(*sys.argv[1:]))
    except (OSError, ValueError, TypeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
