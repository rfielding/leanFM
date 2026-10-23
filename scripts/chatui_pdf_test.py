#!/usr/bin/env python3
"""Check rendered colors and equal text, not merely two PDF filenames.
Requirement: book_palette_selection_is_real_and_stable.
Read only the explicitly selected project's book; no provider requests.
"""
import io
from pathlib import Path
import subprocess
import sys

from PIL import Image


book = Path(sys.argv[1]).resolve(strict=True)
texts = []
for name, dark in [("main.pdf", False), ("main-dark.pdf", True)]:
    path = book / name
    assert path.resolve().is_relative_to(book), "PDF escaped the book directory"
    rendered = subprocess.run(["pdftoppm", "-f", "1", "-singlefile", "-scale-to", "1000",
                               "-png", str(path)], check=True, capture_output=True, timeout=20)
    page = Image.open(io.BytesIO(rendered.stdout)).convert("RGB")
    background = page.getpixel((3, 3))
    if dark:
        assert max(background) < 60, f"{name} has a light background: {background}"
        assert sum(min(pixel) > 180 for pixel in page.getdata()) > 20, "Dark PDF has no legible light text"
    else:
        assert min(background) > 230, f"{name} has a dark background: {background}"
        assert sum(max(pixel) < 100 for pixel in page.getdata()) > 20, "Light PDF has no legible dark text"
    text = subprocess.run(["pdftotext", str(path), "-"], check=True,
                          capture_output=True, timeout=20).stdout
    texts.append(text.split())
assert texts[0] and texts[0] == texts[1], "Light and dark PDFs differ in book content"
print("ok: rendered light/dark PDF backgrounds and text contrast differ; book text is identical")
