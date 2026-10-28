#!/usr/bin/env python3
"""Fail early, with file and line, when a code listing uses a Unicode symbol
that the book's listings `literate=` table in book/main.tex does not map.

pdfLaTeX's listings package cannot typeset unmapped multibyte UTF-8 and stops
with an opaque "Invalid UTF-8 byte sequence" error. Lean source is full of
Unicode, so check every included listing before LaTeX runs.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BOOK = ROOT / "book"


def mapped():
    main = (BOOK / "main.tex").read_text()
    block = main[main.index("literate="):]
    block = block[:block.index("frame=")]
    return set(re.findall(r"\{([^{}\x00-\x7f]+)\}\{\{", block))


def listings():
    """Yield (path, line number, text) for every line typeset by listings."""
    included = set(BOOK.glob("*.lean"))
    for tex in [BOOK / "main.tex", *sorted((BOOK / "chapters").glob("*.tex"))]:
        text = tex.read_text(errors="replace")
        for name in re.findall(r"\\lstinputlisting(?:\[[^\]]*\])?\{([^}]+)\}", text):
            included.add((BOOK / name).resolve())
        inside = False
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r"\\begin\{lstlisting\}", line):
                inside = True
                continue
            if re.search(r"\\end\{lstlisting\}", line):
                inside = False
            elif inside:
                yield tex, number, line
    for path in sorted(included):
        if path.is_file():
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                yield path, number, line


def main():
    known = mapped()
    # Multi-character entries such as ⁻¹ also cover their first character only
    # when that character is mapped on its own, so compare single characters.
    singles = {entry for entry in known if len(entry) == 1}
    problems = []
    for path, number, line in listings():
        for char in sorted(set(line)):
            if ord(char) > 127 and char not in singles:
                problems.append(f"{path.relative_to(ROOT)}:{number}: '{char}' (U+{ord(char):04X})")
    if problems:
        print("Code listings use symbols missing from the literate= table in book/main.tex:", file=sys.stderr)
        for problem in problems[:40]:
            print("  " + problem, file=sys.stderr)
        print("Add each as {sym}{{$\\latexcommand$}}1 to that table.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
