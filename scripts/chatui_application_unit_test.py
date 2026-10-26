#!/usr/bin/env python3
"""Refs: Runtime cleanup never stops unrelated work; Preview cannot borrow engineering authority."""
import sys
sys.dont_write_bytecode=True
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from chatui_application import record,stop,write_record,process_time,check_resources

ROOT=Path(__file__).resolve().parents[1]

class Ownership(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='application-unit-',dir=ROOT/'.cache')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
    def test_forged_pid_with_incidental_launcher_arguments_never_stops_a_process(self):
        # An unrelated Python program can mention the launcher in argv; it still
        # must not be treated as the exact owned supervisor command.
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)',str(ROOT/'scripts/chatui_application.py'),'supervise',str(self.root),'0123456789abcdef'])
        try:
            write_record(self.root,{'root':str(self.root),'owner':'fixture','state':'running','pid':child.pid,'start_time':process_time(child.pid),'instance_id':'0123456789abcdef'})
            stop(self.root,'fixture','0123456789abcdef')
            self.assertIsNone(child.poll(),'an unrelated process was signaled')
        finally:
            child.terminate(); child.wait(timeout=3)
    def test_matching_argv_cannot_disguise_an_unrelated_executable(self):
        child=subprocess.Popen([sys.executable,str(ROOT/'scripts/chatui_application.py'),'supervise',str(self.root),'0123456789abcdef'],executable='/usr/bin/yes',stdout=subprocess.DEVNULL)
        try:
            write_record(self.root,{'root':str(self.root),'owner':'fixture','state':'running','pid':child.pid,'start_time':process_time(child.pid),'instance_id':'0123456789abcdef'})
            stop(self.root,'fixture','0123456789abcdef')
            self.assertIsNone(child.poll(),'argv spoofing caused an unrelated executable to be signaled')
        finally:
            child.terminate(); child.wait(timeout=3)
    def test_copied_root_cannot_control_original_runtime(self):
        write_record(self.root,{'root':str(self.root/'original'),'owner':'other','state':'running','pid':os.getpid(),'start_time':process_time(os.getpid()),'instance_id':'0123456789abcdef'})
        self.assertEqual(record(self.root),{})
        stop(self.root,'fixture')
    def test_runtime_record_symlink_is_rejected(self):
        folder=self.root/'.leanfm/application'; folder.mkdir(parents=True)
        sentinel=self.root/'sentinel'; sentinel.write_text('preserve')
        (folder/'state.json').symlink_to(sentinel)
        with self.assertRaises(ValueError): record(self.root)
        self.assertEqual(sentinel.read_text(),'preserve')
    def test_aggregate_cache_budget_rejects_sparse_exhaustion(self):
        cache=self.root/'cache'; cache.mkdir()
        with (cache/'large').open('wb') as output: output.truncate(513*1024**2)
        with self.assertRaisesRegex(ValueError,'cache budget'): check_resources(os.getpid(),cache)

if __name__=='__main__': unittest.main()
