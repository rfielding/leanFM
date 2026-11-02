"""Minimal JSON-RPC client for the LeanFM MCP endpoint (POST /mcp)."""
import json, os, urllib.request

URL = os.environ.get("LEANFM_MCP", "http://127.0.0.1:8080/mcp")
_id = 0

def rpc(method, params=None):
    global _id
    _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(URL, body, {"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]

def tool(name, arguments):
    res = rpc("tools/call", {"name": name, "arguments": arguments})
    if res.get("structuredContent") is not None:
        return res["structuredContent"], res.get("isError", False)
    text = "".join(c.get("text", "") for c in res.get("content", []))
    try:
        return json.loads(text), res.get("isError", False)
    except ValueError:
        return text, res.get("isError", False)

def resource(uri):
    return rpc("resources/read", {"uri": uri})["contents"][0]["text"]
