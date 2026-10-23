#!/usr/bin/env python3
"""Explicit operator reset: discard projects, preserve encrypted accounts.

Refs: explicit_fresh_start_erases_projects_not_credentials,
Fresh start preserves LeanFM and encrypted accounts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat


def inventory(directory):
    files = {}
    if directory.is_symlink():
        raise ValueError("Cannot inventory a symlink root")
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise ValueError("Credential tree contains a symlink")
        if path.is_file():
            files[str(path.relative_to(directory))] = [hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(path.stat().st_mode)]
    return files


def reset(workspace, apply=False):
    root = Path(workspace).resolve(strict=True)
    if not all((root / path).exists() for path in ["AGENTS.md", "book/main.pdf", "LeanFM/LLMGenerated/Requirements.lean"]):
        raise ValueError("Not a LeanFM workspace root")
    for relative in ["projects", "data", "data/accounts", ".leanfm", ".leanfm/accounts"]:
        if (root / relative).is_symlink():
            raise ValueError("Reset boundary is a symlink: " + relative)
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError("This platform lacks safe project-tree deletion")
    legacy = root / "data/accounts"
    accounts, projects, empty_accounts, scaffolds = [], [], [], []
    if (root / "data").exists() and set(path.name for path in (root / "data").iterdir()) != {"accounts"}:
        raise ValueError("Unrecognized legacy data entry; nothing deleted")
    for account in sorted(legacy.iterdir()) if legacy.exists() else []:
        if account.is_symlink() or not account.is_dir():
            raise ValueError("Unsafe legacy account root")
        if set(p.name for p in account.iterdir()) - {"projects", "password.json", "account.json", "credentials"}:
            raise ValueError("Unrecognized account record; nothing deleted")
        owned = account / "projects"
        if owned.is_symlink():
            raise ValueError("Legacy project container is a symlink")
        for path in sorted(owned.iterdir()) if owned.exists() else []:
            if path.is_symlink() or not path.is_dir():
                raise ValueError("Unsafe or unrecognized legacy project")
            if not (path / "manifest.json").is_file():
                descendants = list(path.rglob("*"))
                if any(child.is_symlink() or not child.is_dir() for child in descendants):
                    raise ValueError("Unrecognized nonempty legacy project")
                scaffolds.extend(descendants + [path])
                continue
            projects.append(path)
        records = {}
        for entry in account.iterdir():
            if entry.name == "projects":
                continue
            if entry.is_symlink():
                raise ValueError("Credential record is a symlink")
            if entry.is_dir():
                records.update({entry.name + "/" + k: v for k, v in inventory(entry).items()})
            else:
                records[entry.name] = [hashlib.sha256(entry.read_bytes()).hexdigest(), stat.S_IMODE(entry.stat().st_mode)]
        destination = root / ".leanfm/accounts" / account.name
        if destination.exists() and inventory(destination) != records:
            raise ValueError("Existing credential destination differs; nothing deleted")
        if records:
            accounts.append((account, destination, records))
        else:
            empty_accounts.append(account)
    base = root / "projects"
    for path in sorted(base.iterdir()) if base.exists() else []:
        if path.is_symlink() or not path.is_dir() or not any((path / name).is_file() for name in ["manifest.json", "project.json"]):
            raise ValueError("Unsafe or unrecognized ordinary project; nothing deleted")
        projects.append(path)
    report = {"operation": "explicit-fresh-start", "project_roots": [str(p.relative_to(root)) for p in projects],
              "accounts_preserved": len(accounts), "empty_scaffolds": [str(p.relative_to(root)) for p in scaffolds], "applied": apply}
    if not apply:
        return report
    vault = root / ".leanfm/accounts"
    vault.mkdir(parents=True, exist_ok=True)
    os.chmod(vault.parent, 0o700)
    os.chmod(vault, 0o700)
    for source, destination, records in accounts:
        if not destination.exists():
            destination.mkdir(mode=0o700)
            for entry in source.iterdir():
                if entry.name == "projects":
                    continue
                if entry.is_dir():
                    shutil.copytree(entry, destination / entry.name, copy_function=shutil.copy2)
                else:
                    shutil.copy2(entry, destination / entry.name)
        if inventory(destination) != records:
            raise ValueError("Credential verification failed; source and projects retained")
    for path in projects:
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Project root changed during reset")
        shutil.rmtree(path)
    for path in sorted(scaffolds, key=lambda p: len(p.parts), reverse=True):
        path.rmdir()
    for account in empty_accounts:
        if (account / "projects").exists():
            (account / "projects").rmdir()
        account.rmdir()
    for source, destination, records in accounts:
        if inventory(destination) != records:
            raise ValueError("Credential destination changed; old account retained")
        shutil.rmtree(source)
    if legacy.exists():
        legacy.rmdir()
    if (root / "data").exists():
        (root / "data").rmdir()
    base.mkdir(exist_ok=True)
    report_path = root / "reports/shared-projects/reset-result.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("workspace")
    parser.add_argument("--apply", action="store_true")
    arguments = parser.parse_args()
    print(json.dumps(reset(arguments.workspace, arguments.apply), indent=2))
