#!/usr/bin/env python3
"""The short test tier: test what changed (selfhost.build.changed-tests).

Asks git what changed, finds every implementation decision whose source files or tests name a
changed file, and runs exactly those decisions' tests, plus the checks that are always cheap.
A changed file no decision names is reported as uncovered.

    python3 -I scripts/changed_tests.py            # test what changed
    python3 -I scripts/changed_tests.py --self-test
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUDGET_S = 120
ALWAYS = [
    ("the self-hosting specification's checks", ["lake", "build", "LeanFM.LLMGenerated.SelfHostingTests"]),
    ("the environment variable list", ["python3", "-I", "scripts/env_registry_check.py"]),
]
PATH = re.compile(r"[\w./-]+\.(?:lean|py|sh)")


def git_changed():
    def run(*args):
        return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.split("\n")
    # tracked changes, staged new files included; untracked files that were never added are not
    # this checkout's work yet (they may be someone's own), so they are left out
    names = run("diff", "--name-only", "HEAD")
    return sorted({n for n in names if n and os.path.exists(os.path.join(ROOT, n))})


def generated(path):
    """Outputs the build writes, checked by what writes them, not by a test of their own."""
    return (path.startswith("book/generated/") or "/book/generated/" in path or path.endswith(".pdf")
            or path.startswith("reports/") or "/reports/" in path or path == "SELF_HOSTING_REVIEW.md"
            or path.endswith("spec/tasks.json"))


def by_kind(changed):
    """Checks a changed file's kind calls for: a protocol file its project's requirement list, a book
    chapter the book's listings, the specification its checks, any Lean file the executables' build."""
    runs, covered = [], set()
    projects = sorted({c.split("/")[1] for c in changed if c.startswith("projects/") and c.endswith(".leanfm")})
    for p in projects:
        runs.append((f"{p}'s requirement list", ["lake", "env", "lean", "--run", "LeanFM/RequirementsCheck.lean", p]))
    if any(c.startswith("LeanFM/LLMGenerated/") and c.endswith(".leanfm") for c in changed):
        runs.append(("LeanFM's requirement list", ["lake", "env", "lean", "--run", "LeanFM/RequirementsCheck.lean", "LeanFM"]))
    books = sorted({c.split("/")[1] for c in changed if c.startswith("projects/") and "/book/" in c and c.endswith(".tex")})
    for p in books:
        if os.path.exists(os.path.join(ROOT, "projects", p, "book", "Makefile")):
            runs.append((f"{p}'s book", ["make", "-C", f"projects/{p}/book"]))
    if any(c.startswith("book/") and c.endswith(".tex") for c in changed):
        runs.append(("the book's listings", ["lake", "env", "lean", "--run", "BookListingsCheck.lean"]))
    if any(c.endswith(".lean") for c in changed):
        runs.append(("the executables' build", ["lake", "build", "LeanFM", "leanfm", "leanfm-server", "leanfm-mcp", "leanfm-diagrams", "leanfm-validate"]))
    for c in changed:
        project_book = c.startswith("projects/") and "/book/" in c and c.endswith(".tex") and \
            os.path.exists(os.path.join(ROOT, "projects", c.split("/")[1], "book", "Makefile"))
        if (project_book or c.endswith(".leanfm") or (c.startswith("book/") and c.endswith(".tex")) or c.startswith("LeanFM/LLMGenerated/")
                or c in ("Main.lean", "Diagrams.lean", "LeanFM.lean", "Validate.lean") or generated(c)):
            covered.add(c)
    return runs, covered


def lean_lists(text, start):
    """The bracketed string lists after `start`, read as JSON (Lean's escapes are JSON's here)."""
    out, i = [], start
    while len(out) < 3:
        i = text.find("[", i)
        if i < 0:
            break
        depth, j, in_str = 0, i, False
        while j < len(text):
            c = text[j]
            if in_str:
                if c == "\\":
                    j += 1
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        try:
            out.append(json.loads(text[i:j + 1]))
        except json.JSONDecodeError:
            out.append([])
        # the description string sits between the files and the tests
        i = j + 1
    return out


def decisions():
    found = []
    registries = glob.glob(os.path.join(ROOT, "LeanFM", "LLMGenerated", "*Implementation.lean")) + \
        glob.glob(os.path.join(ROOT, "LeanFM", "*", "Implementation.lean"))
    for path in sorted(set(registries)):
        text = open(path).read()
        for m in re.finditer(r'decision "([^"]+)"', text):
            lists = lean_lists(text, m.end())
            if len(lists) < 3:
                continue
            refs, files, tests = lists
            strings = lambda xs: [x for x in xs if isinstance(x, str)] if isinstance(xs, list) else []
            found.append((m.group(1), strings(files), strings(tests)))
    return found


def test_paths(entry):
    """The test files a test entry names before its first colon; a planned entry names none."""
    if entry.startswith("planned"):
        return []
    head = entry.split(": ", 1)[0]
    return [p for p in PATH.findall(head) if os.path.exists(os.path.join(ROOT, p))]


def select(changed, decs):
    chosen, covered = {}, set()
    for name, files, tests in decs:
        tpaths = [p for e in tests for p in test_paths(e)]
        hit = [c for c in changed if c in files or c in tpaths]
        if hit:
            covered.update(hit)
            for p in tpaths:
                chosen.setdefault(p, set()).add(name)
    uncovered = [c for c in changed if c not in covered]
    return chosen, uncovered


def command(path):
    if path.endswith(".lean"):
        has_main = re.search(r"^def main\b", open(os.path.join(ROOT, path)).read(), re.M)
        return ["lake", "env", "lean", "--run", path] if has_main else ["lake", "env", "lean", path]
    if path.endswith(".py"):
        return ["python3", "-I", path]
    return ["bash", path]


def self_test():
    decs = [("d", ["a.lean"], ["t.py: checks a", "planned: later"])]
    for p in ("t.py",):
        open(os.path.join("/tmp", p), "w").close()
    global ROOT
    old, ROOT = ROOT, "/tmp"
    try:
        assert select(["a.lean"], decs) == ({"t.py": {"d"}}, [])
        assert select(["t.py"], decs) == ({"t.py": {"d"}}, [])
        assert select(["b.lean"], decs) == ({}, ["b.lean"])
        assert test_paths("planned: later") == []
    finally:
        ROOT = old
    print("ok: changed_tests selects by file and by test, reports the uncovered, and ignores planned entries")


def main():
    if "--self-test" in sys.argv:
        return self_test()
    t0 = time.time()
    changed = git_changed()
    chosen, uncovered = select(changed, decisions())
    kind_runs, kind_covered = by_kind(changed)
    uncovered = [c for c in uncovered if c not in kind_covered]
    print(f"{len(changed)} changed files; {len(chosen)} tests cover them")
    failed = []
    runs = [(f"{p} (for {', '.join(sorted(d))})", command(p)) for p, d in sorted(chosen.items())] + kind_runs + ALWAYS
    for label, cmd in runs:
        s = time.time()
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        ok = r.returncode == 0
        print(f"{'ok' if ok else 'FAILED'} ({time.time() - s:.0f} s): {label}")
        if not ok:
            failed.append(label)
            print("\n".join((r.stdout + r.stderr).strip().split("\n")[-15:]))
    if uncovered:
        print(f"changed, but no test covers it ({len(uncovered)}): " + ", ".join(uncovered[:40]) +
              (f" and {len(uncovered) - 40} more" if len(uncovered) > 40 else ""))
    total = time.time() - t0
    print(f"{len(runs) - len(failed)} of {len(runs)} passed in {total:.0f} s" +
          (f"; over the {BUDGET_S} s budget of the short tier" if total > BUDGET_S else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
