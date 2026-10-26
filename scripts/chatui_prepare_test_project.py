#!/usr/bin/env python3
"""Trusted fixture setup: write and check a fixture specification. No approvals exist."""
import http.cookiejar
import json
from pathlib import Path
import subprocess
import sys
import urllib.request
from chatui_specification_fixture import REQUIREMENTS, PROTO, IMPLEMENTATION

ROOT = Path(__file__).resolve().parents[1]


def prepare(root, post):
    root = Path(root).resolve()
    assert root.is_relative_to(ROOT / ".cache"), "fixture setup cannot touch a live project"
    (root / "spec/Requirements.lean").write_text(REQUIREMENTS)
    (root / "spec/Requirements.proto").write_text(PROTO)
    (root / "spec/Implementation.lean").write_text(IMPLEMENTATION)
    subprocess.run(["python3", str(ROOT / "scripts/chatui_specification.py"), str(root), "Fixture.spec", "Fixture.implementation"],
                   check=True, capture_output=True, text=True, timeout=90)
    from chatui_project_state import current
    state = current(root)
    assert state["requirements"]["checked"] and state["implementation"]["checked"], state


if __name__ == "__main__":
    base, cookie, project, root = sys.argv[1:]
    jar = http.cookiejar.MozillaCookieJar(cookie)
    jar.load(ignore_discard=True, ignore_expires=True)
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    def post(gate, revision):
        request = urllib.request.Request(f"{base}/api/projects/{project}/specification/{gate}/{revision}/accept", data=b"")
        with opener.open(request, timeout=10) as result:
            assert result.status == 200, result.status
    prepare(root, post)
