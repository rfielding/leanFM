#!/usr/bin/env python3
"""Bounded, checked project patches; never execute model-supplied commands.
Requirement refs: recoverable_failures_are_fixed_before_return,
third_party_commands_cross_one_whitelist, equivalent_project_paths_do_not_false_escape.
"""
import os
from pathlib import Path
import subprocess
import sys
from chatui_project_state import authorize_path


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in {"git-apply", "git-apply-check"}:
        return 2
    root = Path(sys.argv[2]).resolve(strict=True)
    patch = sys.stdin.buffer.read(2_000_001)
    if len(patch) > 2_000_000:
        print("Patch exceeds the 2 MB limit.", file=sys.stderr)
        return 1
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(root))
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
        env.pop(name, None)
    paths = subprocess.run(["git", "-C", str(root), "apply", "--numstat", "-z", "--recount", "-"],
                           input=patch, capture_output=True, env=env, timeout=15)
    if paths.returncode == 0:
        chunks = iter(paths.stdout.split(b"\0"))
        try:
            for item in chunks:
                if not item:
                    continue
                path = item.split(b"\t", 2)[-1]
                targets = [path] if path else [next(chunks), next(chunks)]
                for target in targets:
                    authorize_path(root, os.fsdecode(target))
        except (ValueError, OSError, StopIteration) as error:
            print(str(error), file=sys.stderr)
            return 1

    def run(check):
        args = ["git", "-C", str(root), "apply", "--recount", "--verbose", "--whitespace=nowarn"]
        if check:
            args.append("--check")
        result = subprocess.run(args + ["-"], input=patch, capture_output=True, env=env, timeout=15)
        diagnostic = result.stderr.decode("utf-8", errors="replace")
        if "Skipped patch " in diagnostic:
            print("Patch targets were skipped; use project-relative paths. No successful edit is reported.", file=sys.stderr)
            return 1
        if result.returncode:
            # Verbose Git diagnostics may include file contents while searching
            # for context. Retain locations and error classes, never those lines.
            errors = [line for line in diagnostic.splitlines() if line.startswith("error:")]
            print("\n".join(errors)[:6000] or "Git rejected the project patch.", file=sys.stderr)
        return result.returncode

    checked = run(True)
    if checked or sys.argv[1] == "git-apply-check":
        return checked
    return run(False)


if __name__ == "__main__":
    raise SystemExit(main())
