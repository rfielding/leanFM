#!/usr/bin/env python3
"""Add LeanFM to Claude Desktop as a local MCP server (clause selfhost.mcp.stdio).

Claude Desktop starts the command in this entry and speaks MCP with it over standard input and
output. LeanFM's tools never call a model, so this needs no API key; Claude's own turns are part
of the Claude subscription.

  # print the entry (to paste or inspect)
  python3 scripts/claude_desktop_config.py --root /home/me/code/leanFM

  # merge it into this computer's Claude Desktop configuration (a backup is written first)
  python3 scripts/claude_desktop_config.py --root /home/me/code/leanFM --install

  # Claude Desktop on another computer (a Mac), LeanFM built on this one: run there with --ssh
  ssh LINUXHOST cat code/leanFM/scripts/claude_desktop_config.py | \\
    python3 - --ssh LINUXHOST --root /home/me/code/leanFM --install

With --ssh, Claude Desktop runs `ssh HOST ROOT/.lake/build/bin/leanfm-mcp --stdio --root ROOT`, so
ssh must log in without a prompt (a key in ssh-agent, or one without a passphrase). Quit and reopen
Claude Desktop afterwards. Uses only the Python standard library; reads and writes nothing but the
configuration file and its backup.
"""
import argparse
import json
import os
import platform
import shutil
import sys
import time

NAME = "leanfm"


def config_path():
    system = platform.system()
    home = os.path.expanduser("~")
    if system == "Darwin":
        return os.path.join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json")
    if system == "Windows":
        return os.path.join(os.environ.get("APPDATA", os.path.join(home, "AppData", "Roaming")), "Claude", "claude_desktop_config.json")
    return os.path.join(home, ".config", "Claude", "claude_desktop_config.json")


def entry(root, ssh):
    exe = root.rstrip("/") + "/.lake/build/bin/leanfm-mcp"
    if ssh:
        return {"command": "ssh", "args": ["-T", "-o", "BatchMode=yes", ssh, exe, "--stdio", "--root", root]}
    return {"command": exe, "args": ["--stdio", "--root", root]}


def main():
    ap = argparse.ArgumentParser(description="Add LeanFM to Claude Desktop as a local MCP server.")
    ap.add_argument("--root", required=True, help="the LeanFM checkout (absolute path) on the machine that runs leanfm-mcp")
    ap.add_argument("--ssh", help="run leanfm-mcp on this ssh host instead of locally")
    ap.add_argument("--install", action="store_true", help="merge the entry into this computer's Claude Desktop configuration")
    ap.add_argument("--config", help="the configuration file to merge into (default: Claude Desktop's for this system)")
    a = ap.parse_args()
    if not a.root.startswith("/"):
        sys.exit("--root must be an absolute path")
    if a.ssh is not None and (not a.ssh or a.ssh.startswith("-") or any(c.isspace() for c in a.ssh)):
        sys.exit("--ssh must be a host name, such as rob@linuxbox")
    if not a.ssh and not os.path.isfile(entry(a.root, None)["command"]):
        print(f"note: {entry(a.root, None)['command']} does not exist yet; build it with: lake build leanfm-mcp", file=sys.stderr)
    e = entry(a.root, a.ssh)
    if not a.install:
        print(json.dumps({"mcpServers": {NAME: e}}, indent=2))
        return
    path = a.config or config_path()
    config = {}
    if os.path.exists(path):
        with open(path) as f:
            text = f.read()
        try:
            config = json.loads(text) if text.strip() else {}
        except json.JSONDecodeError as err:
            sys.exit(f"{path} is not valid JSON ({err}); fix it or move it aside, then run this again")
        if not isinstance(config, dict):
            sys.exit(f"{path} does not hold a JSON object")
        backup = f"{path}.{time.strftime('%Y%m%d-%H%M%S')}.bak"
        shutil.copy2(path, backup)
        print(f"backup: {backup}")
    servers = config.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        sys.exit(f"{path}: mcpServers is not a JSON object")
    servers[NAME] = e
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print(f"added {NAME} to {path}; quit and reopen Claude Desktop")


if __name__ == "__main__":
    main()
