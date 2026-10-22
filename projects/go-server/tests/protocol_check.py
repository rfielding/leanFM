#!/usr/bin/env python3
"""Actual HTTP -> generated protobuf bytes -> decoded values -> Lean grammar.
No independently handwritten list of legal message sequences is used.
"""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from google.protobuf import json_format

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".cache/proto"))
import Requirements_pb2 as pb

spec = json.loads((ROOT / "spec/tasks.json").read_text())
grammars = {task["id"]: task["grammar"] for task in spec["tasks"]}


def ends(grammar, events, index=0):
    kind = grammar["kind"]
    if kind == "event":
        if index < len(events) and all(events[index][key] == grammar[key] for key in ["task", "src", "dst", "message"]):
            return [index + 1]
        return []
    if kind == "empty":
        return [index]
    if kind == "choice":
        return [end for branch in grammar["children"] for end in ends(branch, events, index)]
    if kind == "seq":
        current = [index]
        for part in grammar["children"]:
            current = [end for start in current for end in ends(part, events, start)]
        return current
    raise AssertionError("Unsupported grammar constructor in this project's conformance checker: " + kind)


def accepts(events):
    task = events[0]["task"]
    return len(events) in ends(grammars[task], events)


def roundtrip(value, cls):
    parsed = json_format.ParseDict(value, cls())
    decoded = cls.FromString(parsed.SerializeToString(deterministic=True))
    assert decoded == parsed
    return decoded


def validate(events):
    assert accepts(events), [event["message"] for event in events]
    assert not events[0]["cause_id"] and not events[0]["prior_ids"]
    ids = [event["id"] for event in events]
    assert len(set(ids)) == len(ids)
    for i, event in enumerate(events):
        roundtrip(event, pb.TraceEvent)
        if i:
            assert event["cause_id"] == ids[0]
            assert event["prior_ids"] == [ids[i - 1]]
            assert event["session"] == events[0]["session"]
    assert not accepts(list(reversed(events)))
    assert not accepts(events[:-1])


def main():
    scenarios = []
    for contract in spec["http"]:
        schema = (ROOT / "spec/views" / (contract["task"] + "-schema.mermaid")).read_text()
        assert "missing task grammar" not in schema
        for name in contract["requests"] + contract["responses"]:
            assert name in schema, ("schema view omitted declared message", name)
    with tempfile.TemporaryDirectory(dir=ROOT / ".cache", prefix="protocol-") as fixture:
        server = subprocess.Popen([str(ROOT / ".cache/goserver"), "-addr", "127.0.0.1:0",
                                   "-data", str((Path(fixture) / "runtime").relative_to(ROOT))],
                                  cwd=ROOT, stdout=subprocess.PIPE, text=True)
        try:
            base = server.stdout.readline().strip().split(" at ", 1)[1]
            with urllib.request.urlopen(base + "/openapi.yaml") as response:
                api = json.load(response)
            assert api["openapi"] == "3.1.0"
            assert len(api["paths"]) == len(spec["http"])
            assert "ledger" in api["components"]["schemas"]["Position"]["properties"]

            def call(path, payload=None, token=None):
                headers = {"Content-Type": "application/json"}
                if token:
                    headers["Authorization"] = "Bearer " + token
                request = urllib.request.Request(base + path, data=None if payload is None else json.dumps(payload).encode(), headers=headers)
                try:
                    response = urllib.request.urlopen(request, timeout=15)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    content = response.read()
                    if response.headers.get_content_type() == "image/gif":
                        assert content[:6] in [b"GIF89a", b"GIF87a"]
                        artifact = ROOT / Path(fixture).relative_to(ROOT) / "runtime" / Path(response.headers["X-GoServer-Artifact"]).name
                        assert artifact.read_bytes() == content
                        events = json.loads(base64.b64decode(response.headers["X-GoServer-Trace"]))
                        data = {"events": events}
                    elif path == "/api/export":
                        events = json.loads(base64.b64decode(response.headers["X-GoServer-Trace"]))
                        data = {"events": events}
                    else:
                        data = json.loads(content)
                        roundtrip(data, pb.Response)
                        events = data["events"]
                    validate(events)
                    contract = next(c for c in spec["http"] if c["task"] == events[0]["task"])
                    assert response.status in contract["statuses"]
                    assert ("GET" if payload is None else "POST") == contract["method"]
                    if payload is not None:
                        roundtrip(payload, getattr(pb, events[0]["message"]))
                    scenarios.append(events)
                    return response.status, data

            _, alice = call("/api/games", {"size": 5, "players": 2, "max_turns": 200, "name": "Alice"})
            room = alice["game"]["id"]
            _, bob = call(f"/api/games/{room}/join", {"name": "Bob"})
            assert call(f"/api/games/{room}/join", {"name": "Extra"})[0] == 409
            call(f"/api/games/{room}")
            call(f"/api/games/{room}/history")
            def action(token, revision, kind, point=0):
                return call(f"/api/games/{room}/actions", {"revision": revision, "action": {"kind": kind, "point": point}}, token)
            assert action(bob["token"], 1, "move")[0] == 403
            assert action(alice["token"], 1, "move")[0] == 200
            assert action(alice["token"], 1, "move", 1)[0] == 409
            assert action(bob["token"], 2, "move", 0)[0] == 422
            assert action(bob["token"], 2, "move", 1)[0] == 200
            action(alice["token"], 3, "pass")
            _, final = action(bob["token"], 4, "pass")
            assert final["game"]["position"]["finished"]
            _, second = call("/api/games", {"size": 5, "players": 2, "max_turns": 200, "name": "Resigner"})
            other = second["game"]["id"]
            call(f"/api/games/{other}/join", {"name": "Opponent"})
            _, resignation = call(f"/api/games/{other}/actions", {"revision": 1, "action": {"kind": "resign", "point": 0}}, second["token"])
            assert resignation["game"]["position"]["finished"]
            call("/api/export", {"size": 5, "players": 2, "max_turns": 200,
                                 "actions": [{"kind": "move", "point": 0}, {"kind": "move", "point": 1}]})
            assert call("/api/export", {"size": 5, "players": 2, "max_turns": 200,
                                 "actions": [{"kind": "move", "point": 0}, {"kind": "move", "point": 0}]})[0] == 422
            browser = json.loads((ROOT / "evidence/playable-v1/browser.json").read_text())
            for events in browser["observed_scenarios"]:
                validate(events)
            report = {"revision": "playable-v1", "result": "pass", "scenarios": len(scenarios),
                      "browser_scenarios": len(browser["observed_scenarios"]),
                      "checks": ["actual HTTP values parse with protoc-generated bindings", "protobuf binary round-trip",
                                 "decoded actor/message sequence accepted by Lean-derived grammar", "reversed and truncated traces rejected",
                                 "cause/prior/session preserved", "all six task contracts exercised", "GIF file exists and matches response bytes"],
                      "observed_scenarios": scenarios}
            (ROOT / "evidence/playable-v1/protocol.json").write_text(json.dumps(report, indent=2) + "\n")
            observed = next(events for events in scenarios if events[0]["task"] == "play_turn" and len(events) == 3)
            mermaid = "sequenceDiagram\n    participant Client\n    participant GoServer\n" + "".join(
                f"    {e['src']}->>{e['dst']}: {e['message']}\n" for e in observed)
            (ROOT / "spec/views/play_turn-observed.mermaid").write_text(mermaid)
            subprocess.run([sys.executable, str(ROOT / "tests/render_contract.py")], check=True)
            print(f"ok: {len(scenarios)} actual HTTP/protobuf/grammar scenarios plus {len(browser['observed_scenarios'])} browser scenarios")
        finally:
            server.terminate()
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
