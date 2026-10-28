#!/usr/bin/env python3
"""Force Lake to rebuild modules whose include_str inputs changed.

Lake hashes a module's Lean source, not the files it pulls in with
include_str (the React bundle, CSS/JS assets, .proto schemas). Instead of
`lake clean` on every build, delete only the build outputs of modules whose
included files are newer than their compiled .olean; Lake then rebuilds those
modules and everything that imports them.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".lake/build"
INCLUDE = re.compile(r'include_str\s+"([^"]+)"')


def main():
    stale = []
    for source in sorted(ROOT.glob("LeanFM/**/*.lean")) + sorted(ROOT.glob("*.lean")):
        text = source.read_text(errors="replace")
        included = [source.parent / name for name in INCLUDE.findall(text)]
        if not included:
            continue
        module = source.relative_to(ROOT).with_suffix("")
        olean = BUILD / "lib/lean" / module.with_suffix(".olean")
        if not olean.exists():
            continue
        built = olean.stat().st_mtime
        if any(path.exists() and path.stat().st_mtime > built for path in included):
            stale.append(module)
    for module in stale:
        for base in [BUILD / "lib/lean", BUILD / "ir"]:
            for output in base.glob(str(module) + ".*"):
                if output.is_file():
                    output.unlink()
        print("rebuild: " + str(module).replace("/", ".") + " (an include_str input changed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
