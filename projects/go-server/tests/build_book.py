#!/usr/bin/env python3
"""Compile both themes in scratch, retaining complete diagnostics and old PDFs.
No paid repair, silent missing-image fallback, or retry of a failed compiler run.
"""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
for variant in ["main", "main-dark"]:
    scratch = ROOT / ".cache/book" / variant
    scratch.mkdir(parents=True, exist_ok=True)
    source = r"\def\darkmode{1}\input{main.tex}" if variant == "main-dark" else "main.tex"
    with (scratch / "compiler-output.log").open("w") as log:
        for _ in range(2):
            result = subprocess.run(["pdflatex", "-file-line-error", "-interaction=nonstopmode", "-halt-on-error",
                                     "-jobname=" + variant, "-output-directory=" + str(scratch), source],
                                    cwd=ROOT / "book", stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                log.flush()
                print((scratch / "compiler-output.log").read_text()[-14000:], file=sys.stderr)
                sys.exit("Book failed; previous PDFs preserved. Full diagnostic: " + str(scratch / "compiler-output.log"))
# Neither public output is replaced until both builds have succeeded.
for variant in ["main", "main-dark"]:
    pending = ROOT / ".cache/book" / (variant + ".pdf")
    shutil.copyfile(ROOT / ".cache/book" / variant / (variant + ".pdf"), pending)
    pending.replace(ROOT / "book" / (variant + ".pdf"))
print("ok: light and dark PDFs compiled from the same source; both promoted after success")
