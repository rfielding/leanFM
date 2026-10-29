#!/usr/bin/env python3
"""Requirement refs: paxos.concurrent.order; web.simple_form.

Two independent browser sessions write concurrently against a running
deployment (`make run`), then each lists the committed map. Screenshots and a
JSON summary land in ../reports/browser/ so the book can include them.
Usage: python3 browser_check.py [base_url]
"""
import asyncio
import json
from pathlib import Path
import sys

from playwright.async_api import async_playwright

BASE = sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:8082'
OUT = Path(__file__).resolve().parent.parent / 'reports' / 'browser'


async def put(page, key, value):
    await page.goto(BASE + '/')
    await page.fill('input[name=key]', key)
    await page.fill('input[name=value]', value)
    await page.click('button')
    await page.wait_for_load_state()


async def rows(page):
    return await page.eval_on_selector_all(
        'tbody tr', 'rs => rs.map(r => [...r.cells].map(c => c.textContent))')


async def main():
    OUT.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        a = await (await browser.new_context(viewport={'width': 900, 'height': 520}, color_scheme='dark')).new_page()
        b = await (await browser.new_context(viewport={'width': 900, 'height': 520}, color_scheme='dark')).new_page()
        await asyncio.gather(put(a, 'color', 'blue'), put(b, 'shape', 'circle'))
        await put(a, 'color', 'green')
        await b.goto(BASE + '/')
        await a.screenshot(path=str(OUT / 'session-a.png'))
        await b.screenshot(path=str(OUT / 'session-b.png'))
        seen_a, seen_b = await rows(a), await rows(b)
        await browser.close()
    expected = [['color', 'green'], ['shape', 'circle']]
    ok = seen_a == expected and seen_b == expected
    summary = {
        'prompt': 'Access the app concurrently from two browser sessions.',
        'question': 'Do both sessions converge on the same committed map, with the later write to a key winning?',
        'base_url': BASE, 'session_a': seen_a, 'session_b': seen_b, 'expected': expected, 'ok': ok,
    }
    (OUT / 'browser-check.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('ok: both sessions see', expected if ok else (seen_a, seen_b))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
