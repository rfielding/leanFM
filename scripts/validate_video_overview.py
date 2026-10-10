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
assert "| af p => !(existsPathAlways" in ctl
assert "| ag p => !(anyReachable" in ctl
assert 'id := "book.overview_video"' in requirements
assert data["id"] == "book.overview_video"
print("ok: video overview provenance and CTL vocabulary match the checked sources")
