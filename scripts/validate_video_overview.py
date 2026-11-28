#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
data = json.loads((root / "video/overview.json").read_text())
ctl = (root / "LeanFM/CTL.lean").read_text()
requirements = (root / "LeanFM/LLMGenerated/Requirements.lean").read_text()
narration = json.loads((root / "video/narration.json").read_text())

expected = ["EF p", "AF p", "EG p", "AG p"]
assert [item["symbol"] for item in data["formulas"]] == expected
assert [item["quantified"][0] for item in data["formulas"]] == ["∃", "∀", "∃", "∀"]
assert all("π" in item["quantified"] and "i" in item["quantified"] for item in data["formulas"])
assert data["dualities"] == ["AG p ⇔ ¬ EF ¬p", "AF p ⇔ ¬ EG ¬p"]
assert [scene["id"] for scene in narration] == [
    "thesis", "alphabet", "grammar", "transition_system", "ctl_coordinates",
    "requirements", "duality", "diffie_hellman", "modal_reading", "conclusion"
]
for constructor in ["| ef :", "| af :", "| eg :", "| ag :"]:
    assert constructor in ctl, constructor
# the dualities the video states: AG is computed as the negation of EF of the negation (the
# checker's label for ag), and AF against the negation of EG of the negation is checked in CTLTests,
# beside the exhaustive comparison with the earlier checker (selfhost.mcp.logic.checker)
tests = (root / "LeanFM/CTLTests.lean").read_text()
assert "| .ag p =>" in ctl and "fun z s => !mem a s || (succ s).any z" in ctl
assert "CTL.holds weakBranches .start (CTL.neg (CTL.ef (CTL.neg weakP)))" in tests
assert "CTL.holds weakBranches .start (CTL.neg (CTL.eg (CTL.neg weakQ)))" in tests
assert "example : disagreements = 0" in tests
assert 'id := "book.overview_video"' in requirements
assert data["id"] == "book.overview_video"
print("ok: video overview provenance and CTL vocabulary match the checked sources")
