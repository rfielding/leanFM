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
ALWAYS_MODULES = [("the self-hosting specification's checks", "LeanFM.LLMGenerated.SelfHostingTests")]
ALWAYS = [("the environment variable list", ["python3", "-I", "scripts/env_registry_check.py"])]
EXECUTABLES = ["LeanFM", "leanfm", "leanfm-server", "leanfm-mcp", "leanfm-diagrams", "leanfm-validate"]
PATH = re.compile(r"[\w./-]+\.(?:lean|py|sh|js)")


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


def test_args(entry, path):
    """The flags an entry writes right after a test's path (scripts/changed_tests.py --self-test)."""
    head = entry.split(": ", 1)[0].split()
    if path not in head:
        return []
    out = []
    for tok in head[head.index(path) + 1:]:
        if not tok.startswith("-"):
            break
        out.append(tok)
    return out


ARGS = {}
DRIVER = {}


def exes():
    """Compiled test executables: lakefile.toml's lean_exe whose root is a module, by that module."""
    try:
        text = open(os.path.join(ROOT, "lakefile.toml")).read()
    except OSError:
        return {}
    pairs = re.findall(r'\[\[lean_exe\]\]\s*name\s*=\s*"([^"]+)"\s*root\s*=\s*"([^"]+)"', text)
    return {root: name for name, root in pairs}


def drivers(decs):
    """A test another test runs (its source names the path) is driven by that test, which gives it
    the files and arguments it needs: chatui_http_check.sh runs chatui_reset_test.py with a fixture."""
    tests = sorted({p for _, _, ts in decs for e in ts for p in test_paths(e)})
    for driver in tests:
        if os.path.basename(driver) == os.path.basename(__file__):
            continue  # the runner names checks it runs itself; it drives nothing as a test
        try:
            text = open(os.path.join(ROOT, driver)).read()
        except OSError:
            continue
        for t in tests:
            if t != driver and t not in DRIVER and re.search(re.escape(t) + r"[\"' ]", text):
                DRIVER[t] = driver


def select(changed, decs):
    chosen, covered = {}, set()
    for name, files, tests in decs:
        tpaths = [p for e in tests for p in test_paths(e)]
        hit = [c for c in changed if c in files or c in tpaths]
        if hit:
            covered.update(hit)
            for p in tpaths:
                chosen.setdefault(p, set()).add(name)
            for e in tests:
                ps = test_paths(e)
                for p in ps:
                    ARGS.setdefault(p, test_args(e, p))
    drivers(decs)
    for p in [p for p in chosen if p in DRIVER]:
        chosen.setdefault(DRIVER[p], set()).update(chosen.pop(p))
    uncovered = [c for c in changed if c not in covered]
    return chosen, uncovered


def module(path):
    """The library module a Lean file under LeanFM/ is (checked by lake build), else None."""
    if path.startswith("LeanFM/") and path.endswith(".lean"):
        return path[:-len(".lean")].replace("/", ".")
    return None


def has_main(path):
    return bool(re.search(r"^def main\b", open(os.path.join(ROOT, path)).read(), re.M))


def failed_modules(output, modules):
    """The modules a lake build output reports failing: a ✖ line naming one, or an error in its file."""
    bad = set()
    for line in output.split("\n"):
        for m in modules:
            f = m.replace(".", "/") + ".lean"
            if ("✖" in line and re.search(re.escape(m) + r"\b", line)) or (line.startswith("error:") and f in line):
                bad.add(m)
    return bad


def command(path):
    if path.endswith(".js"):
        return ["node", path]
    if path.endswith(".lean"):
        has_main = re.search(r"^def main\b", open(os.path.join(ROOT, path)).read(), re.M)
        return ["lake", "env", "lean", "--run", path] if has_main else ["lake", "env", "lean", path]
    if path.endswith(".py"):
        args = ARGS.get(path, [])
        # the runner never runs itself as a whole run, which would recurse
        if os.path.basename(path) == os.path.basename(__file__) and "--self-test" not in args:
            args = ["--self-test"]
        # as make check runs it: the script's own folder stays on the import path for its sibling modules
        return ["python3", path, *args]
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
        assert module("LeanFM/A/BTests.lean") == "LeanFM.A.BTests" and module("Payload.lean") is None
        out = "✔ [1/3] Built LeanFM.A.C\n✖ [2/3] Building LeanFM.A.BTests\nerror: build failed"
        assert failed_modules(out, ["LeanFM.A.BTests", "LeanFM.A.C", "LeanFM.A.B"]) == {"LeanFM.A.BTests"}
        assert command("v.js") == ["node", "v.js"]
        assert test_args("s/x.py --fast: checks", "s/x.py") == ["--fast"]
        assert command("scripts/changed_tests.py")[-1] == "--self-test"
        open("/tmp/v.js", "w").close()
        open("/tmp/M.lean", "w").write('run "v.js" here')
        assert select(["v.js"], [("e", [], ["M.lean and v.js: drives v"])])[0] == {"M.lean": {"e"}}
    finally:
        ROOT = old
    print("ok: changed_tests selects by file and by test, reports the uncovered, ignores planned entries, "
          "names modules, passes an entry's flags, runs a test through the test that drives it, never runs itself whole, reads failed modules from lake's output and runs .js with node")


def say(text):
    print(text, flush=True)


def run_one(label, cmd, failed):
    s = time.time()
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    ok = r.returncode == 0
    say(f"{'ok' if ok else 'FAILED'} ({time.time() - s:.0f} s): {label}")
    if not ok:
        failed.append(label)
        say("\n".join((r.stdout + r.stderr).strip().split("\n")[-15:]))


def main():
    if "--self-test" in sys.argv:
        return self_test()
    t0 = time.time()
    changed = git_changed()
    chosen, uncovered = select(changed, decisions())
    kind_runs, kind_covered = by_kind(changed)
    uncovered = [c for c in uncovered if c not in kind_covered]
    say(f"{len(changed)} changed files; {len(chosen)} tests cover them")
    labels = {p: f"{p} (for {', '.join(sorted(d))})" for p, d in chosen.items()}
    mods = {module(p): labels[p] for p in sorted(chosen) if module(p)}
    mods.update({m: label for label, m in ALWAYS_MODULES})
    compiled = exes()
    mains = [p for p in sorted(chosen) if module(p) and has_main(p)]
    targets = (EXECUTABLES if any(c.endswith(".lean") for c in changed) else []) + sorted(mods) + \
        sorted({compiled[module(p)] for p in mains if module(p) in compiled})
    failed, count = [], 0
    # one lake build: modules already checked are reused, independent ones checked in parallel
    s = time.time()
    r = subprocess.run(["lake", "build", *targets], cwd=ROOT, capture_output=True, text=True)
    out = r.stdout + r.stderr
    bad = failed_modules(out, list(mods)) if r.returncode else set()
    took = time.time() - s
    for m, label in sorted(mods.items(), key=lambda x: x[1]):
        count += 1
        if m in bad or (r.returncode and not bad):
            failed.append(label)
            say(f"FAILED (build {took:.0f} s): {label}")
        else:
            say(f"ok (build {took:.0f} s): {label}")
    if EXECUTABLES[0] in targets:
        count += 1
        if r.returncode and not bad:
            failed.append("the executables' build")
        say(f"{'FAILED' if r.returncode and not bad else 'ok'} (build {took:.0f} s): the executables' build")
    if r.returncode:
        say("\n".join(out.strip().split("\n")[-25:]))
    # a test module's main runs compiled; one with no lean_exe falls back to the interpreter, and says so
    runs = [(labels[p] + " (main)", [os.path.join(".lake", "build", "bin", compiled[module(p)])] if module(p) in compiled
             else ["lake", "env", "lean", "--run", p]) for p in mains if module(p) not in bad]
    for p in mains:
        if module(p) not in compiled:
            say(f"note: {p} has a main but no lean_exe in lakefile.toml, so it runs interpreted (slow)")
    runs += [(labels[p], command(p)) for p in sorted(chosen) if not module(p)] + kind_runs + ALWAYS
    for label, cmd in runs:
        count += 1
        run_one(label, cmd, failed)
    if uncovered:
        say(f"changed, but no test covers it ({len(uncovered)}): " + ", ".join(uncovered[:40]) +
            (f" and {len(uncovered) - 40} more" if len(uncovered) > 40 else ""))
    total = time.time() - t0
    say(f"{count - len(failed)} of {count} passed in {total:.0f} s" +
        (f"; over the {BUDGET_S} s budget of the short tier" if total > BUDGET_S else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
