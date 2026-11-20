#!/usr/bin/env python3
"""Derive the Maqam book's figures from the specification; nothing is drawn by hand.

* renders/maqam-live-{light,dark}.svg: LeanFM's sequence diagram of protocol MaqamLive,
  asked of the running LeanFM server (make serve in the LeanFM root) as session_diagram with
  project Maqam and file spec/Maqam.leanfm, so the server reads the protocol itself;
* renders/<task>.dot: each task's states and transitions from spec/tasks.json, which
  make spec-check derives from spec/Requirements.lean.

Usage (from the project root): python3 scripts/views.py
Writes only under renders/. LEANFM_URL overrides http://127.0.0.1:8080.
"""
import json
import os
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "renders"
URL = os.environ.get("LEANFM_URL", "http://127.0.0.1:8080") + "/mcp"


def call(tool, arguments):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": tool, "arguments": arguments}}).encode()
    request = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        result = json.loads(response.read())["result"]
    if result.get("isError"):
        raise SystemExit(f"{tool}: {result['structuredContent'].get('reason')}")
    return result["structuredContent"]


def dot_of(task):
    terminals = {s["id"] for s in task["states"] if s.get("terminal")}
    lines = [f'digraph "{task["id"]}" {{', '  rankdir=LR; node [shape=box, style=rounded, fontname="Helvetica"]; edge [fontname="Helvetica", fontsize=10];']
    for s in task["states"]:
        shape = ', peripheries=2' if s["id"] in terminals else ''
        lines.append(f'  "{s["id"]}" [label="{s["id"]}\\n{s["label"]}"{shape}];')
    for t in task["transitions"]:
        lines.append(f'  "{t["src"]}" -> "{t["dst"]}" [label="{t["message"]}"];')
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    OUT.mkdir(exist_ok=True)
    for theme in ["light", "dark"]:
        answer = call("session_diagram", {"project": "Maqam", "file": "spec/Maqam.leanfm", "theme": theme})
        (OUT / f"maqam-live-{theme}.svg").write_text(answer["svg"], encoding="utf-8")
        print(f"renders/maqam-live-{theme}.svg: {answer['reading']}")
    catalog = json.loads((ROOT / "spec" / "tasks.json").read_text(encoding="utf-8"))
    for task in catalog["tasks"]:
        (OUT / f"{task['id']}.dot").write_text(dot_of(task), encoding="utf-8")
        print(f"renders/{task['id']}.dot: {len(task['states'])} states, {len(task['transitions'])} transitions")


if __name__ == "__main__":
    main()
