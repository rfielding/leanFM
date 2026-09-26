#!/usr/bin/env python3
"""Prove a legal generated scenario survives protobuf bytes and decoding."""

from __future__ import annotations

import importlib.util
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROTO = ROOT / "LeanFM/LLMGenerated/Requirements.proto"


def load_generated_module(output: Path):
    subprocess.run(
        ["protoc", f"--python_out={output}", f"--proto_path={PROTO.parent}", PROTO.name],
        check=True,
    )
    generated = output / "Requirements_pb2.py"
    spec = importlib.util.spec_from_file_location("leanfm_requirements_pb2", generated)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load generated protobuf module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scenario(pb):
    result = pb.Scenario()
    rows = [
        ("e0", [], "client-1", "gateway-1", 10, "docs_get_request",
         {"method": "GET", "path": "/docs/index.html", "return_to": "Client"}),
        ("e1", ["e0"], "gateway-1", "worker-1", 12, "docs_fetch_command",
         {"path": "/docs/index.html", "cache_mode": "normal", "return_to": "Gateway"}),
        ("e2", ["e1"], "worker-1", "gateway-1", 20, "docs_fetch_result200",
         {"status": 200, "path": "/docs/index.html", "bytes_moved": 4096, "cpu_ms": 3}),
        # The terminal keeps its immediate predecessor and a boundary backpointer
        # to the start, so latency is e3.time_at - e0.time_at.
        ("e3", ["e2", "e0"], "gateway-1", "client-1", 22, "docs_get_response",
         {"status": 200, "path": "/docs/index.html", "bytes_moved": 4096}),
        ("u0", [], "gateway-2", "observer-1", 30, "reliability_unavailable",
         {"actor_spec": "Gateway", "actor_instance": "gateway-2", "reason": "pod restart"}),
        ("r0", ["u0"], "gateway-2", "observer-1", 70, "reliability_recovered",
         {"actor_spec": "Gateway", "actor_instance": "gateway-2"}),
    ]
    for event_id, prior, src, dst, time_at, atom_name, fields in rows:
        event = result.events.add(
            id=event_id, prior=prior,
            session="cluster" if atom_name.startswith("reliability_") else "s1",
            task="reliability" if atom_name.startswith("reliability_") else "get_docs",
            src=src, dst=dst, time_at=time_at,
        )
        atom = getattr(event.message, atom_name)
        for name, value in fields.items():
            setattr(atom, name, value)
    return result


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="leanfm-protobuf-") as directory:
        pb = load_generated_module(Path(directory))
        generated = scenario(pb)
        wire_bytes = generated.SerializeToString(deterministic=True)
        decoded = pb.Scenario()
        decoded.ParseFromString(wire_bytes)
        if decoded != generated:
            raise SystemExit("scenario changed during protobuf round trip")
        if [list(event.prior) for event in decoded.events] != [
            [], ["e0"], ["e1"], ["e2", "e0"], [], ["u0"]
        ]:
            raise SystemExit("decoded causal graph does not reconstruct the scenario")
        print(f"ok: scenario -> {len(wire_bytes)} protobuf bytes -> identical scenario")


if __name__ == "__main__":
    main()
