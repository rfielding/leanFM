#!/usr/bin/env python3
"""Manifest-based shared project discovery; credential accounts are separate."""
import json
from pathlib import Path
import sys


def project(root, identity):
    if not identity or len(identity) > 64 or any(not (c.isalnum() or c in "-_") for c in identity):
        raise ValueError("Invalid project identifier")
    base = root / "projects"
    if base.is_symlink():
        raise ValueError("Projects directory cannot be a symlink")
    path = base / identity
    if path.is_symlink() or not path.is_dir():
        raise ValueError("Project not found")
    if path.resolve().parent != base.resolve():
        raise ValueError("Project root escapes workspace")
    manifest = path / "manifest.json"
    if not manifest.exists():
        manifest = path / "project.json"
    if manifest.is_symlink():
        raise ValueError("Project manifest cannot be a symlink")
    info = json.loads(manifest.read_text())
    if info.get("project_id", info.get("id")) != identity or info.get("root", ".") != ".":
        raise ValueError("Project directory and manifest identity disagree")
    for key in ["book", "dark_book", "book_source", "requirements", "protobuf", "implementation", "tasks", "source", "evidence", "runtime", "cache"]:
        if key not in info:
            continue
        relative = Path(info[key])
        if relative.is_absolute() or ".." in relative.parts or not (path / relative).resolve().is_relative_to(path.resolve()):
            raise ValueError("Manifest path escapes project")
    return path, info


def main(operation, root_name, identity=""):
    root = Path(root_name).resolve(strict=True)
    if operation == "resolve":
        print(project(root, identity)[0])
    elif operation == "list":
        rows = []
        base = root / "projects"
        if base.is_symlink():
            raise ValueError("Projects directory cannot be a symlink")
        for child in sorted(base.iterdir()) if base.exists() else []:
            try:
                path, info = project(root, child.name)
            except (ValueError, OSError, json.JSONDecodeError):
                continue
            rows.append({"project_id": child.name, "display_name": info.get("display_name", info.get("title", child.name)),
                         "read_only": False, "kind": "project"})
        print(json.dumps(rows))
    else:
        raise ValueError("Unknown workspace operation")


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (ValueError, OSError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
