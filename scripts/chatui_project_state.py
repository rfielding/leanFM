#!/usr/bin/env python3
"""Deterministic, revision-bound stakeholder gates. No provider calls.

Refs: shared_projects_have_one_root, shared_project_writers_do_not_collide,
shared_project_paths_never_reach_credentials; develop_project_specification.
"""
import hashlib
import json
from pathlib import Path
import sys
from chatui_specification import atomic, confined, digest

RESERVED = (".leanfm/application", ".leanfm/acceptance.json", ".leanfm/accepted", ".leanfm/work", "reports/specification-check", "reports/runtime-check", "manifest.json", "project.json")


def current(root):
    source_paths = ["book/main.tex", "spec/Requirements.lean", "spec/Requirements.proto"]
    files = {path: digest(confined(root, path)) for path in source_paths}
    catalog_path = confined(root, "spec/tasks.json")
    report_path = confined(root, "reports/specification-check/validation.json")
    try:
        report = json.loads(report_path.read_text())
        catalog = json.loads(catalog_path.read_text())
    except (OSError, ValueError):
        report, catalog = {}, {}
    checked = report.get("status") == "validated" and bool(catalog.get("tasks")) and catalog.get("validation", {}).get("errors") == 0
    checked = checked and all(report.get("artifacts", {}).get(path) == value for path, value in files.items())
    checked = checked and catalog.get("provenance") == report
    revision_files = dict(files)
    if catalog_path.is_file():
        files["spec/tasks.json"] = digest(catalog_path)
        # Checking an implementation changes checker provenance, not the
        # requirements grammar already accepted by the stakeholder.
        revision_files["spec/tasks.json"] = hashlib.sha256(json.dumps({key: catalog.get(key) for key in ["source", "validation", "tasks"]}, sort_keys=True).encode()).hexdigest()
    requirement_revision = hashlib.sha256(json.dumps(revision_files, sort_keys=True).encode()).hexdigest()
    implementation_path = confined(root, "spec/Implementation.lean")
    implementation_hash = digest(implementation_path)
    implementation_checked = checked and bool(report.get("implementation")) and report.get("artifacts", {}).get("spec/Implementation.lean") == implementation_hash
    implementation_revision = hashlib.sha256((requirement_revision + implementation_hash).encode()).hexdigest()
    gate_path = confined(root, ".leanfm/acceptance.json")
    try:
        gates = json.loads(gate_path.read_text())
    except (OSError, ValueError):
        gates = {}
    requirements_accepted = checked and gates.get("requirements", {}).get("revision") == requirement_revision
    implementation_accepted = requirements_accepted and implementation_checked and gates.get("implementation", {}).get("revision") == implementation_revision
    return {"requirements": {"revision": requirement_revision, "checked": bool(checked), "accepted": bool(requirements_accepted)},
            "implementation": {"revision": implementation_revision, "checked": bool(implementation_checked), "accepted": bool(implementation_accepted)},
            "ready": bool(implementation_accepted), "files": files,
            "blocker": "" if implementation_accepted else "Check the current requirements and accept them, then check and accept the typed implementation mapping."}


def authorize_path(root, relative):
    path = confined(root, relative)
    relative = str(path.relative_to(root))
    if any(relative == reserved or relative.startswith(reserved + "/") for reserved in RESERVED):
        raise ValueError("Acceptance, project identity and checker evidence are controlled by LeanFM, not model tools")
    if relative == "source" or relative.startswith("source/"):
        if not current(root)["ready"]:
            raise ValueError("Source writes require both current checked stakeholder acceptance gates")


def accept(root, kind, revision):
    state = current(root)
    if kind not in {"requirements", "implementation"}:
        raise ValueError("Unknown acceptance gate")
    if not state[kind]["checked"] or state[kind]["revision"] != revision:
        raise ValueError("The requested revision is stale or has not passed its canonical check")
    if kind == "implementation" and not state["requirements"]["accepted"]:
        raise ValueError("Accept the current requirements before the implementation mapping")
    directory = confined(root, ".leanfm", directory=True)
    path = confined(root, ".leanfm/acceptance.json")
    try:
        gates = json.loads(path.read_text())
    except (OSError, ValueError):
        gates = {}
    unchanged = gates.get(kind, {}).get("revision") == revision
    if unchanged:
        return current(root)
    gates[kind] = {"revision": revision, "source": "explicit stakeholder acceptance", "files": state["files"]}
    if kind == "requirements" and not unchanged:
        gates.pop("implementation", None)
    snapshot = confined(root, ".leanfm/accepted/" + kind + "/" + revision, directory=True)
    paths = list(state["files"])
    if kind == "implementation":
        paths.append("spec/Implementation.lean")
    for relative in paths:
        destination = confined(root, str((snapshot / relative).relative_to(root)))
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(confined(root, relative).read_bytes())
    atomic(path, json.dumps(gates, indent=2) + "\n")
    manifest_path = confined(root, "manifest.json")
    if manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text())
        manifest["acceptance_file"] = ".leanfm/acceptance.json"
        manifest["acceptance"] = {name: gates.get(name, {}).get("revision", "not-recorded") for name in ["requirements", "implementation"]}
        atomic(manifest_path, json.dumps(manifest, indent=2) + "\n")
    return current(root)


def main(operation, root_name, *arguments):
    root = Path(root_name).resolve(strict=True)
    if operation == "status":
        print(json.dumps(current(root)))
    elif operation == "accept":
        print(json.dumps(accept(root, *arguments)))
    elif operation == "authorize":
        authorize_path(root, *arguments)
        print("OK")
    else:
        raise ValueError("Unknown project-state operation")


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (ValueError, OSError, TypeError) as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
