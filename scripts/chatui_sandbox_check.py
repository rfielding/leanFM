#!/usr/bin/env python3
"""Refs: tool_dependencies_are_complete_and_scoped; executable project isolation.
Fail before a long suite when the required sandbox is missing or unavailable.
"""
import shutil
import subprocess
import sys


def main():
    worker=shutil.which('bwrap')
    if worker is None:
        print('Required bwrap is missing. Install the bubblewrap package (Ubuntu/Debian: sudo apt-get install bubblewrap), then rerun make sandbox-check.',file=sys.stderr)
        return 1
    command=[worker,'--die-with-parent','--new-session','--unshare-all','--cap-drop','ALL']
    for path in ['/usr','/bin','/lib','/lib64']:
        command+=['--ro-bind',path,path]
    command+=['--proc','/proc','--dev','/dev','--tmpfs','/tmp','--clearenv','--setenv','PATH','/usr/bin:/bin','--','/usr/bin/true']
    try: result=subprocess.run(command,capture_output=True,text=True,timeout=10)
    except (OSError,subprocess.SubprocessError) as error:
        print('Required sandbox could not start: '+str(error),file=sys.stderr); return 1
    if result.returncode:
        print('Required sandbox namespace preflight failed (exit '+str(result.returncode)+'). The host must permit user/process/network namespaces for bwrap; check its AppArmor/container policy. No unsandboxed fallback is permitted.\n'+result.stderr[-3000:],file=sys.stderr)
        return 1
    print('ok: required bwrap user/process/network namespace sandbox')
    return 0

if __name__=='__main__': raise SystemExit(main())
