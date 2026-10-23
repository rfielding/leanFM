#!/usr/bin/env python3
"""Two local services must not replace one another's unlocked login cookie.
Requirement refs: one_password_unlocks_all_provider_keys,
proof:Concurrent BYOK isolation, proof:Credential ciphertext requires password login.
Uses only the HTTP suite's disposable encrypted account; no provider calls.
"""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE, DATA = sys.argv[1:]
data = Path(DATA).resolve()
assert data.is_relative_to(ROOT / ".cache") and data.parent.name.startswith("chatui-check.")
assert urllib.parse.urlparse(BASE).hostname == "127.0.0.1"
jar = http.cookiejar.CookieJar()
client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def request(base, path, form=None, cookie=None):
    message = urllib.request.Request(base + path, data=None if form is None else
                                     urllib.parse.urlencode(form).encode())
    if cookie is not None:
        message.add_header("Cookie", cookie)
    try:
        response = (urllib.request.urlopen(message, timeout=5) if cookie is not None else
                    client.open(message, timeout=5))
    except urllib.error.HTTPError as error:
        response = error
    with response:
        response.read()
        return response.status


bundle = data / ".leanfm/accounts/multi_primary/credentials/providers.json"
before = hashlib.sha256(bundle.read_bytes()).digest()
with socket.socket() as allocator:
    allocator.bind(("127.0.0.1", 0))
    port = allocator.getsockname()[1]
other = f"http://127.0.0.1:{port}"
log = (data.parent / "session-port-test.log").open("w")
env = dict(os.environ, LEANFM_PORT=str(port), LEANFM_WORKSPACE_ROOT=str(data),
           LEANFM_OPENAI_BASE_URL="http://127.0.0.1:9/v1",
           LEANFM_ANTHROPIC_BASE_URL="http://127.0.0.1:9/v1")
server = subprocess.Popen([str(ROOT / ".lake/build/bin/leanfm-server")], cwd=ROOT,
                          env=env, stdout=log, stderr=subprocess.STDOUT)
try:
    for _ in range(100):
        assert server.poll() is None, "fixture server exited"
        try:
            if request(other, "/health") == 200:
                break
        except OSError:
            time.sleep(.05)
    form = {"username": "multi_primary", "password": "multi provider test password"}
    assert request(BASE, "/api/login", form) == 200
    assert request(BASE, "/api/me") == 200
    own_name = "leanfm_session_" + str(urllib.parse.urlparse(BASE).port)
    first_token = next(cookie.value for cookie in jar if cookie.name == own_name)
    assert request(other, "/api/login", form) == 200
    assert request(other, "/api/me") == 200
    assert request(BASE, "/api/me") == 200, "another port replaced the first session"
    assert len(set(cookie.name for cookie in jar)) == 2
    # Legacy names remain readable only when the token belongs to that process.
    assert request(BASE, "/api/me", cookie="leanfm_session=" + first_token) == 200
    assert request(other, "/api/me", cookie="leanfm_session=" + first_token) == 401
    assert request(BASE, "/api/me", cookie=own_name + "=invalid; leanfm_session=" + first_token) == 401
    assert hashlib.sha256(bundle.read_bytes()).digest() == before
    result = {"result": "pass", "checks": ["password-only login on both ports", "both sessions retained",
              "legacy-cookie compatibility", "cross-process and invalid-token rejection", "encrypted keys unchanged"]}
    (data.parent / "session-port-test.json").write_text(json.dumps(result, indent=2) + "\n")
    print("ok: independent ports retain their password-unlocked sessions without changing encrypted keys")
finally:
    server.terminate()
    server.wait(timeout=10)
    log.close()
