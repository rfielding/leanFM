#!/usr/bin/env python3
"""Requirement refs: actor:Runtime; spec/runtime.json.

Supervises one Paxos KV deployment: three replicas and one web app, all owned
by this project root. `run` stays in the foreground; `stop` signals only the
process recorded by this project.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parent
CACHE = ROOT / '.cache'
EVENTS = ROOT / 'events'
RECORD = CACHE / 'app-process.json'
BINARY = CACHE / 'paxos-kv'
REPLICAS = [('kv-0', 9100), ('kv-1', 9101), ('kv-2', 9102)]


def start_time(pid):
    return Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]


def stop():
    if RECORD.is_symlink():
        raise ValueError('Runtime record cannot be a symlink')
    if not RECORD.exists():
        print('PaxosKV is stopped')
        return
    data = json.loads(RECORD.read_text())
    pid = data['pid']
    try:
        if start_time(pid) != data['start_time']:
            raise ValueError('Stale process identity; unrelated process left untouched')
        command = Path('/proc', str(pid), 'cmdline').read_bytes().split(b'\0')
        if str(Path(__file__).resolve()).encode() not in command or b'run' not in command:
            raise ValueError('Process is not this project runtime; left untouched')
        os.kill(pid, signal.SIGTERM)
        print('Stopped the project-owned PaxosKV runtime')
    except FileNotFoundError:
        print('PaxosKV is already stopped')


def terminate(processes):
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    for process in processes:
        try:
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def run():
    for path in [CACHE, EVENTS]:
        if path.is_symlink():
            raise ValueError(str(path.name) + ' cannot be a symlink')
        path.mkdir(exist_ok=True)
    port = int(os.environ.get('PAXOS_WEB_PORT', '8082'))
    peers = ','.join(f'{name}=127.0.0.1:{p}' for name, p in REPLICAS)
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    with os.fdopen(os.open(CACHE / 'app.lock', flags, 0o600), 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('This project app is already running; use make stop first') from None

        def interrupted(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        processes = []
        try:
            with os.fdopen(os.open(RECORD, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600), 'w') as record:
                json.dump({'pid': os.getpid(), 'start_time': start_time(os.getpid())}, record)
            for name, p in REPLICAS:
                data = CACHE / 'data' / name
                data.mkdir(parents=True, exist_ok=True)
                processes.append(subprocess.Popen(
                    [str(BINARY), 'replica', '-id', name, '-addr', f'127.0.0.1:{p}', '-peers', peers,
                     '-data', str(data), '-trace', str(EVENTS / f'{name}.jsonl')],
                    cwd=SOURCE, start_new_session=True))
            replicas = ','.join(f'127.0.0.1:{p}' for _, p in REPLICAS)
            processes.append(subprocess.Popen(
                [str(BINARY), 'web', '-addr', f'127.0.0.1:{port}', '-replicas', replicas],
                cwd=SOURCE, start_new_session=True))
            print(f'PaxosKV: http://127.0.0.1:{port}/  (replicas {replicas})', flush=True)
            # Any member exiting ends the deployment; stopping one replica on
            # purpose is done with `kill` on that replica, not through here.
            while all(process.poll() is None for process in processes):
                time.sleep(0.2)
            return 1
        except KeyboardInterrupt:
            return 0
        finally:
            terminate(processes)
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
