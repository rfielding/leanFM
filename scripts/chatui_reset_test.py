#!/usr/bin/env python3
"""LeanFM survives absent examples and repeatedly erased private conversations.
Uses a separate installation cwd and local provider stub, never live user data.
Requirement refs: examples_are_disposable, chat_history_is_not_durable_specification.
"""
import hashlib
import http.cookiejar
import json
import os
import shutil
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
fixture = Path(sys.argv[1]).resolve() / "empty-install"
fixture.mkdir()
# Read-only installation inputs only. No projects symlink or copied example.
for name in ["scripts", "LeanFM", "book", "lakefile.toml"]:
    (fixture / name).symlink_to(ROOT / name)
assert not (fixture / "projects").exists()
with socket.socket() as allocator:
    allocator.bind(("127.0.0.1", 0))
    port = allocator.getsockname()[1]
base = "http://127.0.0.1:" + str(port)
env = dict(os.environ, LEANFM_PORT=str(port), LEANFM_WORKSPACE_ROOT="private-data",
           LEANFM_OPENAI_BASE_URL="http://127.0.0.1:18080/v1", LEANFM_LLM_MODEL="test-model",
           LEANFM_ANTHROPIC_BASE_URL="http://127.0.0.1:18080/anthropic/v1",
           LEANFM_TEST_UNSANDBOXED_BOOK_BUILD="1")
log = (fixture / "server.log").open("w+")
server = subprocess.Popen([str(ROOT / ".lake/build/bin/leanfm-server")], cwd=fixture, env=env,
                          stdout=log, stderr=subprocess.STDOUT)
client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def call(path, fields=None, method=None):
    data = None if fields is None else urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(base + path, data=data, method=method)
    try:
        response = client.open(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read()
        return response.status, json.loads(raw) if raw else None


try:
    for _ in range(100):
        assert server.poll() is None, "isolated LeanFM server exited"
        try:
            urllib.request.urlopen(base + "/health", timeout=.5).close()
            break
        except (OSError, urllib.error.URLError):
            time.sleep(.05)
    # The stub is independently starting alongside this fixture.
    for _ in range(100):
        try:
            request = urllib.request.Request("http://127.0.0.1:18080/v1/models", headers={"Authorization": "Bearer test-user-key"})
            urllib.request.urlopen(request, timeout=.5).close()
            break
        except (OSError, urllib.error.URLError):
            time.sleep(.05)
    status, _ = call("/api/accounts", {"username": "reset_user", "password": "test-reset-password", "openai_api_key": "test-user-key"})
    assert status == 201, status
    status, listed = call("/api/projects")
    assert status == 200 and [p["project_id"] for p in listed["projects"]] == ["leanfm-workspace"], listed
    assert call("/api/projects/go-server/book")[0] == 404
    assert call("/api/projects/go-server-example/book")[0] == 404
    status, created = call("/api/projects", {"display_name": "Resettable project"})
    assert status == 201, created
    project_id = created["project_id"]
    project = fixture / "private-data/projects" / project_id
    assert (project / "book/main.pdf").read_bytes().startswith(b"%PDF")
    assert (project / "book/main-dark.pdf").read_bytes().startswith(b"%PDF")
    for path, text in {
        "book/main.tex": "\\documentclass{article}\n\\usepackage{xcolor}\n\\ifdefined\\darkmode\\pagecolor{black}\\color{white}\\fi\n\\begin{document}\ndurable-book-marker\n\\end{document}\n",
        "spec/Requirements.lean": "-- durable-requirements-marker\n",
        "spec/Requirements.proto": 'syntax = "proto3"; message DurableProtocolMarker {}\n',
        "spec/Implementation.lean": "-- durable-implementation-marker\n",
        "source/resume_marker.txt": "Implementation input retained across chat resets.\n",
    }.items():
        (project / path).write_text(text)
    manifest = json.loads((project / "manifest.json").read_text())
    for key, value in {"root": ".", "book": "book/main.pdf", "dark_book": "book/main-dark.pdf",
                       "book_source": "book/main.tex", "requirements": "spec/Requirements.lean",
                       "protobuf": "spec/Requirements.proto", "implementation": "spec/Implementation.lean",
                       "tasks": "spec/tasks.json", "source": "source/", "evidence": "reports/"}.items():
        assert manifest[key] == value, (key, manifest)
    assert manifest["acceptance"] == {"requirements": "not-recorded", "implementation": "not-recorded"}
    manifest["resume_marker"] = "durable-acceptance-marker"
    manifest["acceptance"] = {"requirements": "not-recorded", "implementation": "not-recorded"}
    (project / "manifest.json").write_text(json.dumps(manifest))
    subprocess.run(["make", "-C", str(project / "book")], cwd=fixture, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    foreign = fixture / "private-data/.leanfm/accounts/foreign/projects/private"
    foreign.mkdir(parents=True)
    (foreign / "manifest.json").write_text('{"display_name":"FOREIGN_PROJECT_SENTINEL"}')
    (foreign / "Requirements.proto").write_text("FOREIGN_PROJECT_SENTINEL")
    paths = ["book/main.tex", "book/main.pdf", "book/main-dark.pdf", "spec/Requirements.lean", "spec/Requirements.proto",
             "spec/Implementation.lean", "manifest.json", "source/resume_marker.txt"]
    before = {p: hashlib.sha256((project / p).read_bytes()).hexdigest() for p in paths}
    for cycle in range(3):
        history = project / "conversations/main.log"
        # Simulate an operator deleting conversation files, not only hiding the UI.
        history.write_text("ERASED_CHAT_SENTINEL")
        history.unlink()
        assert call(f"/api/projects/{project_id}/conversation")[1] == {"messages": []}
        status, result = call(f"/api/projects/{project_id}/chat", {"prompt": "TEST_DURABLE_RESUME", "model": "test-model"})
        assert status == 200 and "Durable resume verified" in result["text"], result
        after = {p: hashlib.sha256((project / p).read_bytes()).hexdigest() for p in paths}
        assert before == after, "chat reset mutated durable artifacts or acceptance"
        assert call("/api/projects/private/book")[0] == 404
    proto_path = project / "spec/Requirements.proto"
    saved_proto = proto_path.read_bytes()
    proto_path.unlink()
    proto_path.symlink_to(foreign / "Requirements.proto")
    status, rejected = call(f"/api/projects/{project_id}/chat", {"prompt": "TEST_DURABLE_RESUME", "model": "test-model"})
    assert status == 404 and "Project not found" in rejected["error"], rejected
    proto_path.unlink()
    proto_path.write_bytes(saved_proto)
    report = {"result": "pass", "example_directory": "absent", "conversation_reset_cycles": 3,
              "checks": ["actual React bundle served", "no phantom example tab or route", "new project with both PDFs",
                         "durable inputs reach provider after each reset", "artifact and acceptance bytes unchanged", "foreign project inaccessible", "symlinked foreign schema excluded from provider context"]}
    # Must be the embedded React application, not an independently served demo.
    with urllib.request.urlopen(base + "/") as response:
        assert b"/assets/chatui-react1.js" in response.read()
    evidence = ROOT / "reports/chatui"
    evidence.mkdir(parents=True, exist_ok=True)
    report["provenance"] = {"prompt": "LeanFM must work when examples and conversations are constantly wiped",
                            "question": "Do startup and continuation still use only the owning project's durable files?",
                            "event_source": "isolated LeanFM HTTP runtime and deterministic local provider",
                            "reducer": "assert absent examples, three erased-chat resumes, byte-preserved canonical artifacts and no foreign context",
                            "unit": "three reset cycles", "boundary": "test installation only; no live accounts or projects"}
    (evidence / "reset-http.json").write_text(json.dumps(report, indent=2) + "\n")
    if os.environ.get("LEANFM_TEST_BROWSER") == "1":
        from chatui_browser_reset import verify_browser
        (project / "conversations/main.log").unlink()
        report["browser"] = verify_browser(base, fixture)
        (evidence / "reset-browser.json").write_text(json.dumps(report, indent=2) + "\n")
        shutil.copyfile(fixture / "react-reset.png", evidence / "reset-browser.png")
    (fixture / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("ok: LeanFM without examples; three erased-chat resumes retain book/spec/protobuf/source and isolation")
except Exception:
    log.flush()
    print((fixture / "server.log").read_text()[-12000:], file=sys.stderr)
    raise
finally:
    server.terminate()
    server.wait(timeout=10)
    log.close()
