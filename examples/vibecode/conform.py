#!/usr/bin/env python3
"""Check a program's log against its protocol with a running LeanFM MCP server.

    python3 examples/vibecode/conform.py examples/vibecode/lending/Lending.protocol log.json
    python3 lending.py --bug | python3 ../conform.py Lending.protocol -

Prints the verdict and each session's first problem; exits 0 when every session conforms, 1 when
one breaks the protocol, 2 when the request itself fails. The server address comes from
LEANFM_MCP_URL (default http://127.0.0.1:8090/mcp); nothing is sent anywhere else, and the proxy
settings of the shell are ignored because the server is local.
"""

import json
import os
import sys
import urllib.request


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    protocol_path, log_path = sys.argv[1], sys.argv[2]
    allow_incomplete = "--incomplete" in sys.argv[3:]
    with open(protocol_path) as f:
        lean = f.read()
    events = json.load(sys.stdin if log_path == "-" else open(log_path))
    url = os.environ.get("LEANFM_MCP_URL", "http://127.0.0.1:8090/mcp")
    request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": "session_conform",
                          "arguments": {"lean": lean, "events": events,
                                        "allowIncomplete": allow_incomplete}}}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(urllib.request.Request(url, json.dumps(request).encode(),
                                                {"Content-Type": "application/json"}),
                         timeout=60) as r:
            reply = json.load(r)
    except OSError as e:
        print(f"could not reach the LeanFM server at {url}: {e}", file=sys.stderr)
        print("start it with: bash scripts/desktop-setup.sh", file=sys.stderr)
        return 2
    result = reply.get("result") or {}
    content = result.get("structuredContent")
    if result.get("isError") or not content:
        text = " ".join(c.get("text", "") for c in result.get("content", []))
        print(text or json.dumps(reply.get("error", reply)), file=sys.stderr)
        return 2
    print(f"{content['verdict']}: {content['reading']}")
    for issue in content.get("issues", []):
        print(f"  {issue}")
    return 0 if content["verdict"] == "conforms" else 1


if __name__ == "__main__":
    sys.exit(main())
