#!/usr/bin/env python3
"""LeanFM's outside programs are all in one list (clause selfhost.setup).

Fails when setup.sh or README.md's install table is not what LeanFM/Deps.lean generates, or when the
Makefile, book/Makefile or a script under scripts/ calls a known outside program that no entry of
LeanFM/Deps.lean provides. Known outside programs are every program the list provides and WATCHED,
programs a contributor might reach for; a call is the program's name as a word on a Makefile recipe
line, or in a script as the program a subprocess call or shutil.which names, or a /bin path.
Usage: deps_check.py [--self-test]
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WATCHED = ["convert", "magick", "inkscape", "rsvg-convert", "docker", "podman", "jq", "wget", "java", "cargo",
           "rustc", "zig", "gcc", "clang", "ffprobe", "sqlite3", "psql", "chromium", "chromium-browser", "pip",
           "pip3", "npx", "yarn", "pnpm", "conda", "lualatex", "xelatex", "qpdf", "gs", "unzip", "zstd"]


def provided(deps_text):
    out = set()
    for m in re.finditer(r'provides := \[([^\]]*)\]', deps_text):
        out |= set(re.findall(r'"([^"]+)"', m.group(1)))
    return out


def calls(name, text, makefile):
    word = re.escape(name)
    if makefile:
        lines = [l for l in text.splitlines() if l.startswith("\t")]
        return any(re.search(rf"(^|[\s;&|(@])({word})(\s|$)", l.split("#")[0]) for l in lines)
    return re.search(rf"""((run|Popen|call|check_call|check_output|which)\(\s*\[?\s*["']|["']/(usr/)?bin/){word}["'\s]""", text) is not None


def unlisted(files, known, have):
    out = []
    for path in files:
        text = open(path).read()
        mk = os.path.basename(path) == "Makefile"
        for name in sorted(known - have):
            if calls(name, text, mk):
                out.append(f"{os.path.relpath(path, ROOT)} calls {name}, which no entry of LeanFM/Deps.lean provides")
    return out


def self_test():
    known = {"jq", "dot"}
    import tempfile
    d = tempfile.mkdtemp()
    mk = os.path.join(d, "Makefile"); open(mk, "w").write("all:\n\tjq . x.json\n# jq in a comment\n")
    py = os.path.join(d, "a.py"); open(py, "w").write('subprocess.run(["dot", "-Tsvg"])\nx = report["jq"]\n')
    assert unlisted([mk], known, {"dot"}) != [], "a recipe calling jq is reported"
    assert unlisted([mk], known, {"jq"}) == [], "a provided program is not"
    assert unlisted([py], known, set()) != [], "a script calling dot is reported"
    open(mk, "w").write("all:\n\techo the jquery docs\n")
    assert unlisted([mk], known, set()) == [], "a word containing the name is not a call"
    print("ok: deps_check self-test")


def main():
    if "--self-test" in sys.argv:
        self_test(); return 0
    problems = []
    subprocess.run(["lake", "build", "LeanFM.Deps"], cwd=ROOT, capture_output=True, text=True)
    r = subprocess.run(["lake", "env", "lean", "--run", "SetupScript.lean", "--check"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        problems.append((r.stderr or r.stdout).strip())
    have = provided(open(os.path.join(ROOT, "LeanFM", "Deps.lean")).read())
    files = [os.path.join(ROOT, "Makefile"), os.path.join(ROOT, "book", "Makefile")] + \
        sorted(glob.glob(os.path.join(ROOT, "scripts", "*.py")) + glob.glob(os.path.join(ROOT, "scripts", "*.sh")))
    files = [f for f in files if os.path.basename(f) != "deps_check.py"]
    problems += unlisted(files, set(WATCHED) | have, have)
    for p in problems:
        print("FAIL:", p)
    if problems:
        return 1
    print(f"ok: setup.sh and the install table match LeanFM/Deps.lean; {len(files)} files call no unlisted outside program")
    return 0


if __name__ == "__main__":
    sys.exit(main())
