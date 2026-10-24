#!/usr/bin/env python3
"""Read-only checks of the current server, with no legacy password or user key.

Requirement refs: selfhost.mcp.readonly, examples_are_disposable,
web_ui_replaces_external_coding_session, stored_provider_keys_are_encrypted.
"""
import json
import base64
import sys
import urllib.error
import urllib.request

BASE = sys.argv[1].rstrip("/")


def request(path, payload=None):
    headers = {"Content-Type": "application/json"} if payload is not None else {}
    req = urllib.request.Request(BASE + path, data=None if payload is None else json.dumps(payload).encode(), headers=headers)
    try:
        result = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        result = error
    with result:
        return result.status, result.read().decode()


assert request("/health") == (200, "ok\n")
status, page = request("/")
assert status == 200 and '/assets/chatui-react1.js' in page
for path, expected in [
    ("requirements-reference", "# LeanFM requirement language reference"),
    ("implementation-reference", "# LeanFM implementation language reference"),
]:
    status, body = request("/tools/leanfm-language/" + path)
    assert status == 200 and body.startswith(expected), (path, status)
status, body = request("/tools/requirements/interrogation")
assert status == 200 and body.startswith("LeanFM requirements interrogation checklist")
for method in ["initialize", "resources/list", "tools/list"]:
    status, body = request("/mcp", {"jsonrpc": "2.0", "id": 1, "method": method,
                                  "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                             "clientInfo": {"name": "http-check", "version": "1"}} if method == "initialize" else {}})
    assert status == 200 and "result" in json.loads(body), (method, status, body)
status, body = request("/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                              "params": {"name": "validate_generated_artifacts", "arguments": {}}})
assert status == 200 and "ok: all generated requirements" in body and "ok: generated implementation" in body
status, body = request("/mcp", {"jsonrpc": "2.0", "id": 3, "method": "resources/read",
                              "params": {"uri": "leanfm://project/book/main.pdf"}})
assert status == 200
book = base64.b64decode(json.loads(body)["result"]["contents"][0]["blob"], validate=True)
assert book.startswith(b"%PDF") and b"%%EOF" in book[-1024:]
assert request("/health") == (200, "ok\n"), "MCP book read stopped the service"
assert request("/api/me")[0] == 401, "smoke check unexpectedly inherited an account session"
print("ok: live health, production ChatUI, live language references and read-only MCP validation; no account credentials used")
