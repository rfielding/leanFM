#!/usr/bin/env python3
"""Compare the implementations manifest.json lists against the one specification.

For each implementation impl/<name>/ this measures what spec/Requirements.lean makes observable
(markdown section "comparison"), so the numbers differ only by language and implementation:

* spec: its status in reports/specification-check/validation.json (make spec-check first);
* check: make -C <source> check, passed or failed, and how long it took;
* render: `make -C <source> render SESSION=... CYCLES=... RATE=... WAV=...` writes the offline
  render, run twice to test that it is deterministic, then compared sample by sample with the
  default implementation's render (the null test: peak and RMS of the difference in dBFS);
* events: the event log that render wrote (MAQAM_EVENT_LOG) checked with LeanFM's session_conform
  against protocol MaqamLive, asked of the running LeanFM server (make serve in the LeanFM root);
* bench: `make -C <source> bench SESSION=... SECONDS=... NAM=...` prints one JSON line with the
  callback times and deadline misses at 64 frames and 48 kHz;
* size: lines of source (comments included), excluding build output.

A target an implementation's Makefile does not have is reported as "not provided", never as a
pass. Writes only reports/compare/ (summary.json, summary.md and per-implementation files).

Usage (from the project root): python3 scripts/compare.py [--session S] [--cycles N]
    [--seconds S] [--nam capture.nam] [--only name,name]
LEANFM_URL overrides http://127.0.0.1:8080.
"""
import argparse
import array
import json
import math
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "reports" / "compare"
URL = os.environ.get("LEANFM_URL", "http://127.0.0.1:8080") + "/mcp"
SKIP = {"target", "zig-out", ".zig-cache", "node_modules", ".nam", "build", "__pycache__"}
SOURCE_SUFFIXES = {".rs", ".zig", ".mojo", ".🔥", ".py", ".c", ".h", ".go"}
TIMEOUT = 1800


def implementations():
    manifest = json.loads((ROOT / "manifest.json").read_text())
    listed = manifest.get("implementations") or [
        {"name": "default", "implementation": "spec/Implementation.lean", "source": manifest.get("source", "source/")}]
    default = manifest.get("default_implementation", listed[0]["name"])
    return sorted(listed, key=lambda item: item["name"] != default), default


def inside(relative):
    path = (ROOT / relative).resolve()
    if path != ROOT and ROOT not in path.parents:
        raise SystemExit("path escapes the project: " + relative)
    return path


def has_target(source, target):
    makefile = source / "Makefile"
    if not makefile.is_file():
        return False
    return subprocess.run(["make", "-C", str(source), "-n", target], capture_output=True).returncode == 0


def make(source, target, variables, log, env=None):
    started = time.monotonic()
    arguments = ["make", "-C", str(source), target] + [key + "=" + str(value) for key, value in variables.items()]
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=TIMEOUT,
                                env=dict(os.environ, **(env or {})))
    except subprocess.TimeoutExpired:
        log.write_text("timed out after " + str(TIMEOUT) + " s\n")
        return None, time.monotonic() - started, ""
    log.write_text(result.stdout + result.stderr)
    return result.returncode, time.monotonic() - started, result.stdout


def read_wav(path):
    with wave.open(str(path), "rb") as handle:
        frames = handle.readframes(handle.getnframes())
        width, rate, channels = handle.getsampwidth(), handle.getframerate(), handle.getnchannels()
    if width == 4:
        samples = array.array("f", frames)
    elif width == 2:
        samples = array.array("f", (value / 32768.0 for value in array.array("h", frames)))
    else:
        raise ValueError("unsupported WAV sample width " + str(width))
    return samples, rate, channels


def read_float_wav(path):
    """WAV with IEEE float data (format 3), which the wave module refuses."""
    data = path.read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a WAV file")
    offset, rate, channels, bits, body = 12, None, None, None, None
    while offset + 8 <= len(data):
        chunk, size = data[offset:offset + 4], int.from_bytes(data[offset + 4:offset + 8], "little")
        if chunk == b"fmt ":
            channels = int.from_bytes(data[offset + 10:offset + 12], "little")
            rate = int.from_bytes(data[offset + 12:offset + 16], "little")
            bits = int.from_bytes(data[offset + 22:offset + 24], "little")
        elif chunk == b"data":
            body = data[offset + 8:offset + 8 + size]
        offset += 8 + size + (size & 1)
    if body is None or bits != 32:
        raise ValueError("expected 32-bit float WAV data")
    return array.array("f", body), rate, channels


def samples_of(path):
    try:
        return read_wav(path)
    except Exception:
        return read_float_wav(path)


def decibels(value):
    return None if value <= 0 else round(20 * math.log10(value), 1)


def difference(left_path, right_path):
    left, left_rate, left_channels = samples_of(left_path)
    right, right_rate, right_channels = samples_of(right_path)
    if (left_rate, left_channels) != (right_rate, right_channels):
        return {"comparable": False, "reason": "sample rate or channel count differs"}
    count = min(len(left), len(right))
    peak, energy = 0.0, 0.0
    for a, b in zip(left[:count], right[:count]):
        d = abs(a - b)
        peak = max(peak, d)
        energy += d * d
    rms = math.sqrt(energy / count) if count else 0.0
    return {"comparable": True, "samples": count, "length_difference": abs(len(left) - len(right)),
            "peak_dbfs": decibels(peak), "rms_dbfs": decibels(rms), "identical": peak == 0.0 and len(left) == len(right)}


def conform(events_path):
    events = [json.loads(line) for line in events_path.read_text().splitlines() if line.strip()]
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "session_conform",
                       "arguments": {"project": "Maqam", "file": "spec/Maqam.leanfm", "events": events,
                                     "allowIncomplete": True}}}).encode()
    request = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            result = json.loads(response.read())["result"]
    except (urllib.error.URLError, OSError) as error:
        return {"status": "not checked", "reason": "LeanFM server unreachable (make serve): " + str(error)}
    content = result.get("structuredContent", {})
    return {"status": "error" if result.get("isError") else content.get("verdict", "unknown"),
            "events": len(events), "detail": content.get("reason") or content.get("problems")}


def source_lines(source):
    total = 0
    for path in source.rglob("*"):
        if any(part in SKIP for part in path.relative_to(source).parts):
            continue
        if path.is_file() and path.suffix in SOURCE_SUFFIXES:
            total += sum(1 for _ in path.open(errors="replace"))
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--session", default="impl/rust/source/default.mq")
    parser.add_argument("--cycles", type=int, default=2)
    parser.add_argument("--rate", type=int, default=48000)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--nam", default="")
    parser.add_argument("--only", default="")
    options = parser.parse_args()
    session = inside(options.session)
    listed, default = implementations()
    only = {name for name in options.only.split(",") if name}
    validation_path = ROOT / "reports/specification-check/validation.json"
    validation = json.loads(validation_path.read_text()) if validation_path.is_file() else {}
    OUT.mkdir(parents=True, exist_ok=True)
    results, reference = {}, None
    for item in listed:
        name = item["name"]
        if only and name not in only:
            continue
        source = inside(item["source"])
        out = OUT / name
        out.mkdir(exist_ok=True)
        result = {"default": name == default, "source": item["source"]}
        spec = validation.get("implementations", {}).get(name)
        result["spec"] = spec["status"] if spec else "not checked (run make spec-check)"
        if not source.is_dir():
            result["check"] = "no source"
            results[name] = result
            continue
        result["source_lines"] = source_lines(source)
        if has_target(source, "check"):
            code, seconds, _ = make(source, "check", {}, out / "check.log")
            result["check"] = {"passed": code == 0, "seconds": round(seconds, 1)}
        else:
            result["check"] = "not provided"
        if has_target(source, "render"):
            renders = []
            for run in (1, 2):
                wav, events = out / ("render-" + str(run) + ".wav"), out / ("events-" + str(run) + ".jsonl")
                events.unlink(missing_ok=True)
                code, seconds, _ = make(source, "render", {"SESSION": session, "CYCLES": options.cycles,
                                                            "RATE": options.rate, "WAV": wav},
                                        out / ("render-" + str(run) + ".log"), {"MAQAM_EVENT_LOG": str(events)})
                renders.append((code, seconds, wav, events))
            ok = all(code == 0 and wav.is_file() for code, _, wav, _ in renders)
            result["render"] = {"passed": ok, "seconds": round(renders[0][1], 1)}
            if ok:
                result["render"]["deterministic"] = difference(renders[0][2], renders[1][2]).get("identical", False)
                if name == default:
                    reference = renders[0][2]
                elif reference is not None:
                    result["render"]["null_test_vs_" + default] = difference(reference, renders[0][2])
                events = renders[0][3]
                result["events"] = conform(events) if events.is_file() else {"status": "no event log written"}
        else:
            result["render"] = "not provided"
        if has_target(source, "bench"):
            code, seconds, stdout = make(source, "bench", {"SESSION": session, "SECONDS": options.seconds,
                                                            "NAM": options.nam}, out / "bench.log")
            lines = [line for line in stdout.splitlines() if line.startswith("{")]
            try:
                result["bench"] = json.loads(lines[-1]) if code == 0 and lines else {"passed": False}
            except json.JSONDecodeError:
                result["bench"] = {"passed": False, "reason": "bench did not print a JSON line"}
        else:
            result["bench"] = "not provided"
        results[name] = result
    summary = {"session": options.session, "cycles": options.cycles, "rate": options.rate,
               "bench_seconds": options.seconds, "nam": options.nam or None, "default_implementation": default,
               "implementations": results}
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (OUT / "summary.md").write_text(markdown(summary))
    print((OUT / "summary.md").read_text())


def cell(value):
    if isinstance(value, dict):
        if "passed" in value and len(value) <= 3:
            return ("pass" if value["passed"] else "FAIL") + (" " + str(value["seconds"]) + " s" if "seconds" in value else "")
        return ", ".join(key + " " + str(item) for key, item in value.items() if not isinstance(item, (dict, list)))
    return str(value)


def markdown(summary):
    rows = ["# Implementations of the Maqam specification", "",
            "Session " + summary["session"] + ", " + str(summary["cycles"]) + " cycles at " + str(summary["rate"]) +
            " Hz; bench " + str(summary["bench_seconds"]) + " s at 64 frames, 48 kHz" +
            (", NAM " + summary["nam"] if summary["nam"] else "") + ".", "",
            "| implementation | spec | check | render | null test | events | bench | source lines |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name, result in summary["implementations"].items():
        render = result.get("render", "")
        null = ""
        if isinstance(render, dict):
            test = next((value for key, value in render.items() if key.startswith("null_test")), None)
            if test and test.get("comparable"):
                null = "identical" if test["identical"] else "peak " + str(test["peak_dbfs"]) + " dBFS, rms " + str(test["rms_dbfs"]) + " dBFS"
            elif test:
                null = test.get("reason", "")
            render = cell({key: value for key, value in render.items() if key in ("passed", "seconds")}) + \
                (", deterministic" if render.get("deterministic") else ", NOT deterministic" if render.get("passed") else "")
        events = result.get("events", {})
        rows.append("| " + " | ".join([name + (" (default)" if result["default"] else ""), str(result["spec"]),
                                        cell(result.get("check", "")), cell(render), null,
                                        str(events.get("status", "")) if isinstance(events, dict) else str(events),
                                        cell(result.get("bench", "")), str(result.get("source_lines", ""))]) + " |")
    return "\n".join(rows) + "\n"


if __name__ == "__main__":
    main()
