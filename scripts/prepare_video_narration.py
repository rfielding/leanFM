#!/usr/bin/env python3
"""Synthesize scene-local Piper speech and emit exact Manim scene durations."""

import argparse
import json
import subprocess
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIDEO = ROOT / "video"
PYTHON = VIDEO / ".conda" / "bin" / "python"
PIPER = VIDEO / ".conda" / "bin" / "piper"


def run(*args: str, stdin: str | None = None) -> None:
    subprocess.run(args, input=stdin, text=stdin is not None, check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="en_US-lessac-medium")
    parser.add_argument("--gap", type=float, default=0.65)
    parser.add_argument("--project", default="video")
    args = parser.parse_args()

    global VIDEO
    VIDEO = (ROOT / args.project).resolve()
    if not VIDEO.is_relative_to(ROOT):
        raise SystemExit("narration project must remain below the project root")

    scenes = json.loads((VIDEO / "narration.json").read_text(encoding="utf-8"))
    voices = ROOT / "video" / "voices"
    model = voices / f"{args.model}.onnx"
    audio_dir = VIDEO / "audio"
    voices.mkdir(exist_ok=True)
    audio_dir.mkdir(exist_ok=True)
    if not model.exists():
        run(str(PYTHON), "-m", "piper.download_voices", "--download-dir", str(voices), args.model)

    timings = {}
    parts = []
    for scene in scenes:
        wav_path = audio_dir / f"{scene['id']}.wav"
        run(str(PIPER), "--model", str(model), "--output_file", str(wav_path), stdin=scene["text"])
        with wave.open(str(wav_path), "rb") as source:
            params = source.getparams()
            frames = source.readframes(source.getnframes())
            duration = source.getnframes() / source.getframerate()
        timings[scene["id"]] = duration + args.gap
        parts.append((params, frames))

    output = VIDEO / "narration.wav"
    with wave.open(str(output), "wb") as target:
        target.setparams(parts[0][0])
        for params, frames in parts:
            if (params.nchannels, params.sampwidth, params.framerate) != (
                parts[0][0].nchannels, parts[0][0].sampwidth, parts[0][0].framerate
            ):
                raise SystemExit("Piper produced incompatible scene audio")
            target.writeframes(frames)
            target.writeframes(b"\0" * int(args.gap * params.framerate) * params.nchannels * params.sampwidth)

    (VIDEO / "timings.json").write_text(json.dumps(timings, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {output} ({sum(timings.values()):.1f} seconds)")


if __name__ == "__main__":
    main()
