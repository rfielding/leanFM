#!/usr/bin/env python3
"""Mux prepared Piper narration with the Manim render."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIDEO = ROOT / "video"
silent = VIDEO / "leanfm-overview.mp4"
narration = VIDEO / "narration.wav"
output = VIDEO / "leanfm-overview-narrated.mp4"

for path in (silent, narration):
    if not path.exists():
        raise SystemExit(f"missing generated input: {path}")

subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-i", str(silent), "-i", str(narration),
    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac",
    "-b:a", "160k", "-shortest", str(output),
], check=True)
print(output)
