#!/usr/bin/env python3
"""R6: real CLI rejects path escape, intermediate symlinks and public binding."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
checks = []
with tempfile.TemporaryDirectory(dir=ROOT / ".cache", prefix="startup-") as fixture:
    fixture = Path(fixture)
    (fixture / "target").mkdir()
    (fixture / "link").symlink_to(fixture / "target", target_is_directory=True)
    for args, diagnostic in [(["-data", "../escape"], "escapes project root"),
                             (["-data", str(fixture / "absolute")], "must remain beneath"),
                             (["-data", str((fixture / "link/child").relative_to(ROOT))], "symlink"),
                             (["-addr", "0.0.0.0:0", "-data", str((fixture / "public").relative_to(ROOT))], "loopback")]:
        result = subprocess.run([str(ROOT / ".cache/goserver")] + args, cwd=ROOT,
                                capture_output=True, text=True, timeout=5)
        assert result.returncode != 0 and diagnostic in result.stderr, result.stderr
        checks.append(diagnostic)
    assert not (fixture / "target/child").exists()
(ROOT / "evidence/playable-v1/startup.json").write_text(json.dumps({"revision": "playable-v1", "result": "pass", "checks": checks}, indent=2) + "\n")
print("ok: CLI rejects parent/absolute path escape, intermediate symlink and non-loopback bind")
