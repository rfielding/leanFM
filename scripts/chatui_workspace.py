#!/usr/bin/env python3
"""Manifest-owned project identities in readable, exclusive directories.

Refs: shared_projects_have_one_root, shared_storage_preserves_project_identity,
shared_project_paths_never_reach_credentials, migration_never_overwrites_or_loses_state.
"""
import json
from pathlib import Path
import re
import sys


def valid_identity(identity):
    return isinstance(identity, str) and 0 < len(identity) <= 64 and all(
        c.isalnum() or c in "-_" for c in identity) and identity != "leanfm-workspace"


def project_base(root):
    base = root / "projects"
    if base.is_symlink() or base.resolve().parent != root:
        raise ValueError("Projects directory cannot be a symlink or escape the workspace")
    return base


def read_project(base, path):
    if path.is_symlink() or not path.is_dir() or path.resolve().parent != base.resolve():
        raise ValueError("Project root escapes workspace")
    manifest = path / "manifest.json"
    if manifest.is_symlink():
        raise ValueError("Project manifest cannot be a symlink")
    if not manifest.exists():
        manifest = path / "project.json"
    if manifest.is_symlink():
        raise ValueError("Project manifest cannot be a symlink")
    info = json.loads(manifest.read_text())
    if not isinstance(info, dict) or not valid_identity(info.get("project_id", info.get("id"))) or info.get("root", ".") != ".":
        raise ValueError("Invalid project manifest identity or root")
    for key in ["book", "dark_book", "book_source", "requirements", "protobuf", "implementation", "tasks", "source", "evidence", "runtime", "cache", "acceptance_file"]:
        if key not in info:
            continue
        relative = Path(info[key])
        if relative.is_absolute() or ".." in relative.parts or not (path / relative).resolve().is_relative_to(path.resolve()):
            raise ValueError("Manifest path escapes project")
    return path, info


def discover(root):
    base = project_base(root)
    found = []
    for child in sorted(base.iterdir()) if base.exists() else []:
        try:
            found.append(read_project(base, child))
        except (ValueError, OSError, TypeError):
            continue
    return found


def identity_of(info):
    return info.get("project_id", info.get("id"))


def project(root, identity):
    if not valid_identity(identity):
        raise ValueError("Invalid project identifier")
    matches = [(path, info) for path, info in discover(root) if identity_of(info) == identity]
    if len(matches) != 1:
        raise ValueError("Project not found or manifest identity is ambiguous")
    return matches[0]


def reserve(root, name):
    # A filesystem label, never a caller-supplied path or an argument to a shell.
    stem = re.sub(r"[^A-Za-z0-9_-]+", "-", name).strip("-_")[:56].rstrip("-_") or "Project"
    base = project_base(root)
    base.mkdir(exist_ok=True)
    identities = {identity_of(info) for _, info in discover(root)}
    for ordinal in range(1, 10001):
        identity = stem if ordinal == 1 else f"{stem}-{ordinal}"
        if not valid_identity(identity) or identity in identities:
            continue
        path = base / identity
        try:
            path.mkdir()  # Atomic reservation: collisions never adopt an existing root.
        except FileExistsError:
            continue
        return path, identity
    raise ValueError("No available project directory name; no existing project was changed")


def main(operation, root_name, identity=""):
    root = Path(root_name).resolve(strict=True)
    if operation == "resolve":
        print(project(root, identity)[0])
    elif operation == "create":
        path, project_id = reserve(root, identity)
        print(json.dumps({"project_id": project_id, "root": str(path)}))
    elif operation == "list":
        found = discover(root)
        counts = {}
        for _, info in found:
            key = identity_of(info)
            counts[key] = counts.get(key, 0) + 1
        rows = [{"project_id": identity_of(info), "display_name": info.get("display_name", info.get("title", path.name)),
                 "read_only": False, "kind": "project"}
                for path, info in found if counts[identity_of(info)] == 1]
        print(json.dumps(rows))
    else:
        raise ValueError("Unknown workspace operation")


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (ValueError, OSError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
