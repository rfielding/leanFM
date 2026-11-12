#!/usr/bin/env python3
"""Turn SVG diagrams that LeanFM generated into PDFs the book can include.

Usage: python3 scripts/svg_to_pdf.py book/generated/lang-*.svg

Each foo.svg becomes foo.pdf beside it, one page exactly the SVG's size, with its own background
(light diagrams for book/main.pdf, dark ones for book/main-dark.pdf). The SVG is rendered by
headless Chromium through Playwright; nothing is redrawn, so the PDF shows what LeanFM drew.
An SVG without a numeric width and height is refused rather than guessed at.
"""
import re
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright


def size(svg: str) -> tuple[float, float]:
    head = svg[: svg.find(">") + 1]
    w = re.search(r'\bwidth="([0-9.]+)"', head)
    h = re.search(r'\bheight="([0-9.]+)"', head)
    if not (w and h):
        raise SystemExit("an SVG needs numeric width and height on its root element")
    return float(w.group(1)), float(h.group(1))


def main(paths: list[str]) -> None:
    if not paths:
        raise SystemExit(__doc__)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        for name in paths:
            src = Path(name)
            svg = src.read_text(encoding="utf-8")
            w, h = size(svg)
            page.set_content(
                "<!doctype html><html><head><style>html,body{margin:0;padding:0}"
                "svg{display:block}</style></head><body>" + svg + "</body></html>"
            )
            out = src.with_suffix(".pdf")
            page.pdf(path=str(out), width=f"{w}px", height=f"{h}px", print_background=True,
                     margin={"top": "0", "right": "0", "bottom": "0", "left": "0"})
            print(f"wrote {out} ({w:g} x {h:g} px)")
        browser.close()


if __name__ == "__main__":
    main(sys.argv[1:])
