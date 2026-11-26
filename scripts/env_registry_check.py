#!/usr/bin/env python3
"""Every environment variable LeanFM reads is in one list (selfhost.env.registry).

Compares the variables the Lean sources name (string literals with LeanFM's prefixes, and every
literal passed to getEnv) with the names in LeanFM/Env.lean, both ways, and checks that every name
holding a credential (ending in _KEY, _TOKEN, _PASSWORD or _SECRET) is marked secret there.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIXED = re.compile(r'"((?:LEANFM_|OPENAI_|ANTHROPIC_)[A-Z0-9_]+)"')
GETENV = re.compile(r'getEnv\s+"([A-Za-z0-9_]+)"')
CREDENTIAL = ("_KEY", "_TOKEN", "_PASSWORD", "_SECRET")


def sources():
    for base in ["LeanFM", "."]:
        top = os.path.join(ROOT, base)
        for dirpath, dirs, files in os.walk(top):
            if base == ".":
                dirs[:] = []  # only the executables' own files at the root
            dirs[:] = [d for d in dirs if d not in ("LLMGenerated", ".lake")]
            for f in files:
                if f.endswith(".lean") and "Tests" not in f and f != "Env.lean":
                    yield os.path.join(dirpath, f)


def main():
    env_text = open(os.path.join(ROOT, "LeanFM", "Env.lean")).read()
    listed = {}
    for m in re.finditer(r'\{ name := "([A-Za-z0-9_]+)"(.*?)\}', env_text):
        listed[m.group(1)] = "secret := true" in m.group(2)
    named = set()
    for path in sources():
        text = open(path).read()
        named |= set(PREFIXED.findall(text)) | set(GETENV.findall(text))
    missing = sorted(named - set(listed))
    unused = sorted(set(listed) - named)
    unmarked = sorted(n for n, secret in listed.items() if n.endswith(CREDENTIAL) and not secret)
    ok = True
    if missing:
        print("error: read but not in LeanFM/Env.lean:", ", ".join(missing)); ok = False
    if unused:
        print("error: in LeanFM/Env.lean but never read:", ", ".join(unused)); ok = False
    if unmarked:
        print("error: a credential not marked secret:", ", ".join(unmarked)); ok = False
    if not ok:
        sys.exit(1)
    print(f"ok: {len(listed)} environment variables, the list and the source agree, {sum(listed.values())} secret")


if __name__ == "__main__":
    main()
