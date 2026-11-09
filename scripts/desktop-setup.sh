#!/usr/bin/env bash
# Set up LeanFM for Claude Desktop (Linux or macOS): build the MCP-only server, (re)start it on
# 127.0.0.1:$LEANFM_MCP_PORT, and add a "leanfm" entry to Claude Desktop's configuration without
# touching the other entries. Safe to rerun after a git pull.
#
# Positive: after it succeeds, the server answers at http://127.0.0.1:$PORT/mcp and the config
#   names it through `npx -y mcp-remote`.
# Negative: it writes no credentials; it changes only the "leanfm" entry of mcpServers and keeps a
#   backup of the previous config next to it; it stops only the server it started itself (pid file
#   under .cache/); the server's log and pid stay under this project's .cache/ directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${LEANFM_MCP_PORT:-8090}"
STATE="$ROOT/.cache/desktop"
mkdir -p "$STATE"
cd "$ROOT"

case "$(uname -s)" in
  Darwin) CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
  *)      CFG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" ;;
esac

if ! command -v lake >/dev/null 2>&1; then
  if [ -x "$HOME/.elan/bin/lake" ]; then
    export PATH="$HOME/.elan/bin:$PATH"
  else
    echo "Installing elan (the Lean toolchain manager) into ~/.elan ..."
    curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --default-toolchain none
    export PATH="$HOME/.elan/bin:$PATH"
  fi
fi
command -v npx >/dev/null 2>&1 || {
  echo "npx (Node.js) is needed for the mcp-remote bridge. On Ubuntu: sudo apt install nodejs npm"; exit 1; }

echo "Building leanfm-mcp (the first build takes a while) ..."
lake build leanfm-mcp

if [ -f "$STATE/leanfm-mcp.pid" ]; then
  old="$(cat "$STATE/leanfm-mcp.pid")"
  if kill -0 "$old" 2>/dev/null && ps -p "$old" -o args= | grep -q leanfm-mcp; then
    kill "$old"; sleep 1
  fi
fi
LEANFM_MCP_PORT="$PORT" nohup "$ROOT/.lake/build/bin/leanfm-mcp" >"$STATE/leanfm-mcp.log" 2>&1 &
echo $! >"$STATE/leanfm-mcp.pid"

for _ in $(seq 1 20); do
  if curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' "http://127.0.0.1:$PORT/mcp"; then
    ok=1; break
  fi
  sleep 0.5
done
[ "${ok:-}" = 1 ] || { echo "The server did not answer; see $STATE/leanfm-mcp.log"; exit 1; }
echo "LeanFM MCP server running at http://127.0.0.1:$PORT/mcp (log: $STATE/leanfm-mcp.log)"

python3 - "$CFG" "$PORT" <<'PY'
import json, os, shutil, sys
path, port = sys.argv[1], sys.argv[2]
data = {}
backed_up = False
if os.path.exists(path):
    with open(path) as f:
        text = f.read()
    try:
        data = json.loads(text) if text.strip() else {}
    except ValueError as e:
        sys.exit(f"{path} is not valid JSON ({e}); nothing was changed. Fix it, or move it aside and rerun.")
    if not isinstance(data, dict) or not isinstance(data.get("mcpServers", {}), dict):
        sys.exit(f"{path} does not hold an object with an mcpServers object; nothing was changed.")
    shutil.copy(path, path + ".bak")
    backed_up = True
entry = {"command": "npx", "args": ["-y", "mcp-remote", f"http://127.0.0.1:{port}/mcp"]}
servers = data.setdefault("mcpServers", {})
if servers.get("leanfm") == entry:
    print(f"Claude Desktop already points at LeanFM ({path})")
else:
    servers["leanfm"] = entry
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    note = " (previous version saved as .bak)" if backed_up else ""
    print(f"Added LeanFM to {path}{note}; restart Claude Desktop")
PY

cat <<'TXT'

Quit and reopen Claude Desktop, then start a conversation with, for example:

  Use LeanFM's design_with_session_types prompt to design a library-lending service:
  members borrow and return books, a librarian approves holds. Review it with session_review
  until it is clean, show the diagram and each role's typestate, animate 20 members, generate
  the code with session_skeleton, implement it, and conform its logs.

TXT
