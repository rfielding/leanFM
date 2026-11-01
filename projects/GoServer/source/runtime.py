#!/usr/bin/env python3
"""Requirement refs: goserver; uniform foreground run and project-owned stop."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
CACHE = SOURCE.parent / '.cache'
RECORD = CACHE / 'app-process.json'

def start_time(pid):
    return Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]

def stop():
    if RECORD.is_symlink():
        raise ValueError('Runtime record cannot be a symlink')
    if not RECORD.exists():
        print('GoServer is stopped')
        return
    data = json.loads(RECORD.read_text())
    pid = data['pid']
    try:
        if start_time(pid) != data['start_time'] or Path('/proc', str(pid), 'cwd').resolve() != SOURCE:
            raise ValueError('Stale process identity; unrelated process left untouched')
        command = Path('/proc', str(pid), 'cmdline').read_bytes().split(b'\0')
        if str(Path(__file__).resolve()).encode() not in command or b'run' not in command:
            raise ValueError('Process is not this project runtime; left untouched')
        os.kill(pid, signal.SIGTERM)
        print('Stopped the project-owned GoServer process')
    except FileNotFoundError:
        print('GoServer is already stopped')

def run():
    if CACHE.is_symlink():
        raise ValueError('Project cache cannot be a symlink')
    CACHE.mkdir(exist_ok=True)
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    with os.fdopen(os.open(CACHE / 'app.lock', flags, 0o600), 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('This project app is already running; use make stop first') from None
        process = None
        def interrupted(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        try:
            with os.fdopen(os.open(RECORD, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600), 'w') as record:
                json.dump({'pid':os.getpid(), 'start_time':start_time(os.getpid())}, record)
            process = subprocess.Popen([str(CACHE / 'goserver')], cwd=SOURCE, start_new_session=True)
            return process.wait()
        except KeyboardInterrupt:
            return 0
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            RECORD.unlink(missing_ok=True)

if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['stop']:
            stop()
        elif sys.argv[1:] == ['run']:
            raise SystemExit(run())
        else:
            raise ValueError('Use run or stop')
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
