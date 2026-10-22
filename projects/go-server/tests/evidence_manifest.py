#!/usr/bin/env python3
"""Bind durable R1..R6 controls/tests to exact project inputs and evidence."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / "evidence/playable-v1"
reports = {name: json.loads((out / (name + ".json")).read_text()) for name in ["rules", "protocol", "browser", "startup"]}
assert all(r["result"] == "pass" for r in reports.values())
controls = [
    {"requirement": "R1", "positive": "Exactly one immutable validated transition is published",
     "forbidden": "Rejected or unpersisted action changes authoritative state",
     "control": ["source/game/game.go:Apply", "source/server/server.go:commit"],
     "negative_tests": ["TestRejectedMoveUnchanged", "TestDeadlinePassesAndPersistenceFailure"], "evidence": ["rules.json", "protocol.json"]},
    {"requirement": "R2", "positive": "Both runtimes agree on board, losses, signed ledger and complete score vector",
     "forbidden": "Incorrect capture order, immortal edge groups, or unsigned suicide accounting",
     "control": ["source/game/game.go", "source/server/web/rules.mjs"],
     "negative_tests": ["TestEdgeHasNoImmortalLiberty", "TestSuicideSignedLedger", "TestSeveralGroupsAndOwnGroupCaptureOrder", "TestScoreAndNeutralRegions", "tests/rules_check.mjs"], "evidence": ["rules.json"]},
    {"requirement": "R3", "positive": "Only current authenticated seat at exact revision may act",
     "forbidden": "Impersonation, replay, wrong-seat mutation, double commit, plaintext token persistence",
     "control": ["source/server/server.go:api", "source/server/server.go:save", "source/server/web/app.mjs:connect"],
     "negative_tests": ["TestUnauthorizedStaleAndIllegalActionsDoNotMutate", "TestConcurrentSameRevisionCommitsExactlyOnce", "TestTwoPlayersCompleteGameAndRestart", "tests/browser_check.py"], "evidence": ["protocol.json", "browser.json"]},
    {"requirement": "R4", "positive": "Review preserves immutable ancestors and sibling variations",
     "forbidden": "Network review issues moves or stale worker results mutate another selected position",
     "control": ["source/server/web/app.mjs:append/select/think/synchronize"],
     "negative_tests": ["tests/browser_check.py:branch siblings, blocked review, seat reload", "tests/rules_check.mjs:input freeze"], "evidence": ["browser.json", "board-labels.txt"]},
    {"requirement": "R5", "positive": "Real GIF ends at selected path, replayed through Go rules",
     "forbidden": "Invented or illegal frames, missing-file claims, user-selected filesystem targets",
     "control": ["source/server/export.go:ReplayExport/EncodeGIF/export"],
     "negative_tests": ["TestGIFReplaysExactSelectedPath", "TestStorageBoundsAndCorruptRestart", "tests/protocol_check.py", "tests/browser_check.py"], "evidence": ["protocol.json", "selected-line.gif", "browser.json"]},
    {"requirement": "R6", "positive": "Finite resources and project-confined state; failures retain specific diagnostics",
     "forbidden": "Path/symlink escape, public binding, cross-origin mutation, DNS rebinding, ambiguous JSON, unlimited work/storage, paid retry loops",
     "control": ["source/cmd/goserver/main.go", "source/server/server.go:Handler/decode", "source/server/web/rules.mjs:search", "tests/build_book.py"],
     "negative_tests": ["TestOriginBodyAndPathBoundaries", "TestStrictJSONAndLoopbackHost", "TestStorageBoundsAndCorruptRestart", "TestParameterBounds", "tests/startup_check.py", "tests/rules_check.mjs:node/work limits"], "evidence": ["startup.json", "rules.json", "protocol.json"]}
]
paths = []
for directory in ["source", "tests", "spec", "book", "evidence/playable-v1"]:
    paths += [p for p in (ROOT / directory).rglob("*") if p.is_file() and
              p.suffix in [".go", ".mod", ".mjs", ".html", ".css", ".yaml", ".lean", ".proto", ".json", ".tex", ".pdf", ".png", ".gif", ".txt", ".py", ".mermaid"]
              and "legacy" not in p.parts and "internal" not in p.parts and "api" not in p.parts
              and p.name != "traceability.json"]
paths += [ROOT / name for name in ["project.json", "README.md", "Makefile"]]
hashes = {}
for path in sorted(set(paths)):
    assert path.resolve().is_relative_to(ROOT)
    hashes[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
report = {"revision": "playable-v1", "scope": "Operator-requested implementation experiment; no retroactive acceptance or deployed-code refinement theorem",
          "commands": ["make check", "make browser-check", "make book"],
          "tools": {"python": platform.python_version(), "node": subprocess.check_output(["node", "--version"], text=True).strip(),
                    "protoc": subprocess.check_output(["protoc", "--version"], text=True).strip()},
          "results": {name: {k: v for k, v in r.items() if k not in ["observed_scenarios", "selected_state"]} for name, r in reports.items()},
          "traceability": controls, "sha256": hashes,
          "remaining": ["Fresh-agent regeneration from only durable artifacts", "General GrammarExpr recognition and deployed-code refinement", "Optimal or strong MCTS play", "Production network deployment and fault tolerance"]}
(out / "traceability.json").write_text(json.dumps(report, indent=2) + "\n")
print("ok: R1..R6 controls, negative tests, exact input/evidence hashes retained")
