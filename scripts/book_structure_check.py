#!/usr/bin/env python3
"""The book's implicit structure (clause selfhost.book.structure): a prose paragraph is roughly five
sentences, and about five paragraphs in a row start a new subsection titled for the next idea.

Reads book/main.tex's preface and book/chapters/*.tex. A paragraph is a run of prose lines between
blank lines; listings, figures, tables, tool outputs and other environments are not prose and do not
count, but they do not break a run of paragraphs either. Reports each paragraph over MAX_SENTENCES
sentences, two neighbouring paragraphs with nothing between them that together have at most five
(join them), and each run of
more than MAX_RUN paragraphs with no \\section, \\subsection or \\subsubsection.
Usage: book_structure_check.py [--strict] [files...]; --strict exits non-zero when anything is reported.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_SENTENCES = 7
MAX_RUN = 8
HEADING = re.compile(r"\\(chapter|section|subsection|subsubsection|paragraph)\*?\{")
SKIP_ENVS = ("lstlisting", "figure", "table", "tabular", "longtable", "verbatim", "align", "equation",
             "itemize", "enumerate", "description", "center", "minipage", "tikzpicture", "quote")


def blocks(text):
    """Prose paragraphs and headings, in order: ("h", title) or ("p", text, line)."""
    out, cur, start, depth = [], [], 0, 0
    def flush():
        nonlocal cur
        if cur:
            out.append(("p", " ".join(cur), start))
        cur = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("%")[0] if not raw.lstrip().startswith("\\%") else raw
        s = line.strip()
        if any(s.startswith("\\begin{" + e) for e in SKIP_ENVS):
            flush(); depth += 1; out.append(("e", s, n))
        if depth:
            if any(("\\end{" + e) in s for e in SKIP_ENVS):
                depth -= 1
            continue
        if HEADING.match(s):
            flush(); out.append(("h", s, n)); continue
        if not s:
            flush(); continue
        if s.startswith("\\") and not re.match(r"\\(emph|texttt|textsf|textbf|sloppy|noindent|S\b|ref|cite)", s):
            # a command line (\ToolOutput, \label, \input, \ToolShot ...) is not prose
            flush(); out.append(("e", s, n)); continue
        if not cur:
            start = n
        cur.append(s)
    flush()
    return out


def sentences(p):
    t = re.sub(r"\\[a-zA-Z]+\*?(\[[^\]]*\])?", "", p)
    t = re.sub(r"\b(e\.g|i\.e|etc|vs|cf)\.", "", t)
    t = re.sub(r"\d\.\d", "", t)
    return max(1, len(re.findall(r"[.!?](?=[\s})]|$)", t)))


def check(path):
    issues = []
    text = open(path).read()
    if path.endswith("main.tex"):
        a, b = text.find("\\chapter*{Preface}"), text.find("\\mainmatter")
        if a < 0 or b < 0:
            return issues
        text = "\n" * text[:a].count("\n") + text[a:b]
    run, run_start, prev = 0, 0, None
    for blk in blocks(text):
        if blk[0] == "h":
            run = 0; prev = None; continue
        if blk[0] == "e":
            prev = None; continue
        _, p, line = blk
        k = sentences(p)
        if prev is not None and prev + k <= 5 and not p.rstrip().endswith(":"):
            issues.append(f"{os.path.relpath(path, ROOT)}:{line}: a paragraph of {k} after one of {prev}, with nothing between: join them (aim for about 5)")
        prev = k
        if k > MAX_SENTENCES:
            issues.append(f"{os.path.relpath(path, ROOT)}:{line}: a paragraph of {k} sentences (aim for about 5)")
        run += 1
        if run == 1:
            run_start = line
        if run == MAX_RUN + 1:
            issues.append(f"{os.path.relpath(path, ROOT)}:{run_start}: more than {MAX_RUN} paragraphs without a subsection (aim for one about every 5)")
    return issues


def self_test():
    import tempfile
    def issues(body):
        with tempfile.NamedTemporaryFile("w", suffix=".tex", delete=False) as f:
            f.write("\\chapter{T}\n\n" + body)
        try:
            return check(f.name)
        finally:
            os.unlink(f.name)
    para = lambda k: " ".join(f"Sentence {i}." for i in range(k))
    assert any("8 sentences" in i for i in issues(para(8))), "a long paragraph is reported"
    assert any("join" in i for i in issues(para(2) + "\n\n" + para(2))), "two short neighbours are reported"
    listing = "\n\n\\begin{lstlisting}\nOne. Two. Three. Four. Five. Six. Seven. Eight.\n\\end{lstlisting}\n\n"
    assert issues(para(2) + listing + para(2)) == [], "a listing between them, and its lines, are not prose"
    assert any("without a subsection" in i for i in issues("\n\n".join(para(5) for _ in range(9)))), "nine paragraphs are reported"
    assert issues("\n\n".join(para(5) for _ in range(8))) == [], "eight paragraphs are not"
    print("ok: book_structure_check self-test")


def main():
    if "--self-test" in sys.argv:
        self_test(); return 0
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    files = args or [os.path.join(ROOT, "book", "main.tex")] + sorted(glob.glob(os.path.join(ROOT, "book", "chapters", "*.tex")))
    issues = [i for f in files for i in check(f)]
    for i in issues:
        print(i)
    print(f"{'ok' if not issues else 'warning'}: book structure: {len(issues)} paragraphs or runs over the bounds in {len(files)} files")
    return 1 if issues and "--strict" in sys.argv else 0


if __name__ == "__main__":
    sys.exit(main())
