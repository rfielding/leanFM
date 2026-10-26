#!/usr/bin/env python3
"""Deterministic project specification status. No provider calls.

Review and acceptance are git commits: LeanFM records no approvals and blocks
no edit, source write or launch on one. It reports whether the canonical check
is current and whether the specification files are committed.

Refs: shared_projects_have_one_root, shared_project_writers_do_not_collide,
shared_project_paths_never_reach_credentials; develop_project_specification.
"""
import hashlib
import json
from pathlib import Path
import subprocess
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
    git = git_status(root, list(files) + ["spec/Implementation.lean"])
    return {"requirements": {"revision": requirement_revision, "checked": bool(checked),
                             "committed": git["committed"](list(files))},
            "implementation": {"revision": implementation_revision, "checked": bool(implementation_checked),
                               "committed": git["committed"](["spec/Implementation.lean"])},
            "ready": True, "files": files, "git": {"repository": git["repository"], "uncommitted": git["uncommitted"]},
            "blocker": ""}


def git_status(root, paths):
    """Committed means tracked by git with no working-tree or staged change."""
    # Project files are untrusted: never let repository config run code
    # (fsmonitor, hooks, external diff or textconv drivers).
    def run(*arguments):
        return subprocess.run(["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                               "-c", "diff.external=", "-C", str(root), *arguments],
                              capture_output=True, text=True, timeout=10,
                              env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "HOME": "/nonexistent"})
    try:
        inside = run("rev-parse", "--is-inside-work-tree")
    except (OSError, subprocess.TimeoutExpired):
        inside = None
    if inside is None or inside.returncode != 0 or inside.stdout.strip() != "true":
        return {"repository": False, "uncommitted": [], "committed": lambda _: None}
    if run("check-ignore", "-q", ".").returncode == 0:
        # e.g. an example project under LeanFM's ignored projects/ directory.
        return {"repository": False, "uncommitted": [], "committed": lambda _: None}
    existing = [path for path in paths if (root / path).exists()]
    tracked = set(run("ls-files", "--", *existing).stdout.split()) if existing else set()
    changed = run("diff", "--no-ext-diff", "--no-textconv", "--name-only", "--relative", "HEAD", "--", *existing) if existing else None
    dirty = set(changed.stdout.split()) if changed is not None and changed.returncode == 0 else set(existing)
    uncommitted = sorted(path for path in existing if path not in tracked or path in dirty)
    return {"repository": True, "uncommitted": uncommitted,
            "committed": lambda group: all(path not in uncommitted for path in group if path in existing)}


def authorize_path(root, relative):
    path = confined(root, relative)
    relative = str(path.relative_to(root))
    if any(relative == reserved or relative.startswith(reserved + "/") for reserved in RESERVED):
        raise ValueError("Acceptance, project identity and checker evidence are controlled by LeanFM, not model tools")


def main(operation, root_name, *arguments):
    root = Path(root_name).resolve(strict=True)
    if operation == "status":
        print(json.dumps(current(root)))
    elif operation == "accept":
        raise ValueError("LeanFM records no approvals; review and commit the specification with git")
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
