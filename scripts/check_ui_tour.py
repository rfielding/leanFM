#!/usr/bin/env python3
"""Refs: ui_capture_artifacts_drive_book_tasks; No visual-only UI evidence.
Reject missing, altered or stale screenshot/accessibility/focus evidence.
"""
import hashlib
import json
from pathlib import Path
import re
import sys


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def check(root):
    folder=root/'book/assets/ui-tour'
    manifest=json.loads((folder/'manifest.json').read_text())
    chapter=(root/'book/chapters/chat-ui-guide.tex').read_text()
    required=set(re.findall(r'\\UITourFigure\{([^}]+)\}',chapter))
    captures={item['name']:item for item in manifest['captures']}
    if required!=set(captures): raise ValueError('Required Chat UI capture set does not match its manifest')
    for name,expected in manifest['source_sha256'].items():
        if Path(name).is_absolute() or '..' in Path(name).parts: raise ValueError('Capture source path escapes the project')
        if digest(root/name)!=expected: raise ValueError('Stale Chat UI captures for '+name+'; run make ui-snapshots')
    requirement=digest(folder/'example-Requirements.lean')
    catalog=json.loads((folder/'example-tasks.json').read_text())
    if catalog.get('validation',{}).get('errors')!=0 or not catalog.get('tasks'): raise ValueError('Capture task snapshot is not validated')
    if catalog['provenance']['artifacts']['spec/Requirements.lean']!=requirement: raise ValueError('Task snapshot and requirement input disagree')
    for name,item in captures.items():
        if not re.fullmatch(r'[0-9]{2}-[a-z-]+',name): raise ValueError('Invalid capture name')
        for key in ['prompt','question','boundary','event_source','reducer','unit','browser','captured_at']:
            if not item.get(key): raise ValueError('Missing capture provenance: '+name+' '+key)
        if item.get('requirements_sha256')!=requirement: raise ValueError('Capture requirement revision mismatch: '+name)
        expected_files={name+'.png',name+'.accessibility.json',name+'.keyboard.json'}
        if set(item['artifacts'])!=expected_files: raise ValueError('Missing visual/accessibility/keyboard evidence: '+name)
        for filename,expected in item['artifacts'].items():
            path=folder/filename
            if path.is_symlink() or digest(path)!=expected: raise ValueError('Altered capture evidence: '+filename)
        png=(folder/(name+'.png')).read_bytes()
        if not png.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError('Capture is not PNG: '+name)
        accessible=json.loads((folder/(name+'.accessibility.json')).read_text())
        if not accessible.get('nodes') or not accessible.get('focused'): raise ValueError('No accessible control state: '+name)
        if not isinstance(json.loads((folder/(name+'.keyboard.json')).read_text()),list): raise ValueError('Invalid keyboard trace: '+name)
    return len(captures)


if __name__=='__main__':
    try:
        root=Path(__file__).resolve().parents[1]
        print('ok: '+str(check(root))+' current Chat UI screenshots, accessibility snapshots and keyboard traces')
    except (ValueError,OSError,KeyError) as error:
        print('Chat UI capture validation failed: '+str(error),file=sys.stderr)
        raise SystemExit(1)
