#!/usr/bin/env python3
"""Real application launch, stale evidence and confined process ownership."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from chatui_runtime import status, revision
from chatui_project_state import authorize_path

ROOT=Path(__file__).resolve().parents[1]

class Runtime(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='runtime-check-',dir=ROOT/'.cache')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for name in ['spec','source','.leanfm']:
            (self.root/name).mkdir()
        self.profile={'version':1,'kind':'http','directory':'source','command':['make','run'],'host':'127.0.0.1','port':8081,'readiness_path':'/health','page_path':'/'}
        self.write_profile()
        (self.root/"spec/ProjectMemory.md").write_text("Goal: run this isolated fixture; keep launch failures and verification durable.\n")
        (self.root/'.leanfm/acceptance.json').write_text('private gate sentinel')
        (self.root/'source/Makefile').write_text('run:\n\tpython3 app.py\n')
        (self.root/'source/app.py').write_text('''import os,pathlib,socket
from http.server import BaseHTTPRequestHandler,HTTPServer
assert not os.getenv('LEANFM_TEST_SECRET')
assert not pathlib.Path('/home/rfielding/.ssh').exists()
try:
    pathlib.Path('../.leanfm/acceptance.json').write_text('forged')
except OSError:
    pass
else:
    raise RuntimeError('gate was writable')
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
HTTPServer(('127.0.0.1',8081),Handler).serve_forever()
''')
    def write_profile(self):
        (self.root/'spec/runtime.json').write_text(json.dumps(self.profile))
    def check(self):
        return subprocess.run(['bash',str(ROOT/'scripts/chatui_command.sh'),'check-runtime',str(self.root)],capture_output=True,text=True,timeout=120,env=dict(os.environ,LEANFM_TEST_SECRET='not-visible-in-worker'))
    def test_actual_run_receipt_is_current_then_becomes_stale(self):
        result=self.check()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(status(self.root)['valid'])
        self.assertEqual((self.root/'.leanfm/acceptance.json').read_text(),'private gate sentinel')
        with self.assertRaises(ValueError):
            authorize_path(self.root,'reports/runtime-check/validation.json')
        (self.root/'source/app.py').write_text('raise SystemExit(7)\n')
        self.assertFalse(status(self.root)['valid'])
        result=self.check()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('exit_code=2',result.stdout+result.stderr)
        self.assertFalse(status(self.root)['valid'])
    def test_reserved_port_commands_paths_and_symlinks_are_rejected(self):
        for key,value in [('port',8080),('host','0.0.0.0'),('command',['sh','-c','true']),('directory','../other')]:
            original=self.profile[key];self.profile[key]=value;self.write_profile()
            result=self.check();self.assertNotEqual(result.returncode,0,result.stdout)
            self.profile[key]=original
        self.write_profile()
        (self.root/'source/foreign').symlink_to(self.root/'.leanfm',target_is_directory=True)
        with self.assertRaises(ValueError):revision(self.root)
    def test_bind_all_interfaces_cannot_be_labeled_successful(self):
        p=self.root/'source/app.py';p.write_text(p.read_text().replace("('127.0.0.1',8081)","('0.0.0.0',8081)"))
        result=self.check();self.assertNotEqual(result.returncode,0)
        self.assertIn('listen only',result.stdout+result.stderr)
        self.assertFalse(status(self.root)['valid'])

if __name__=='__main__':unittest.main()
