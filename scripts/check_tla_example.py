#!/usr/bin/env python3
"""Book example: execute pinned TLC, retain evidence, render measured state counts."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / 'book/examples/tla'
JAR = ROOT / '.toolchains/tla/tla2tools-1.7.4.jar'
EXPECTED = '936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88'

def main():
    if not JAR.exists():
        raise SystemExit('Run make tla-toolchain first; checker is an explicit optional dependency.')
    assert hashlib.sha256(JAR.read_bytes()).hexdigest() == EXPECTED, 'unexpected TLC artifact'
    cache = MODEL / '.tlc'
    cache.mkdir(exist_ok=True)
    rows = []
    for config, bits, clock in [('Baseline', 0, 0), ('Cache4', 4, 0), ('Cache8', 8, 0), ('Clock7', 0, 7)]:
        started = time.monotonic()
        run = subprocess.run(['java', '-XX:+UseParallelGC', '-Xmx512m', '-cp', str(JAR), 'tlc2.TLC',
                              '-workers', '1', '-metadir', str(cache/config),
                              '-config', config+'.cfg', 'OrderQueue.tla'],
                             cwd=MODEL, text=True, capture_output=True, timeout=120)
        log = run.stdout + run.stderr
        (cache/(config+'.log')).write_text(log)
        if run.returncode != 0 or 'Model checking completed. No error has been found.' not in log:
            raise SystemExit(log)
        match = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found', log)
        assert match, log
        rows.append(dict(config=config, cache_bits=bits, clock_bound=clock,
                         generated=int(match[1].replace(',', '')),
                         distinct=int(match[2].replace(',', '')),
                         elapsed_seconds=round(time.monotonic()-started, 3)))
    base = rows[0]['distinct']
    for row in rows:
        assert row['distinct'] == base * 2**row['cache_bits'] * (row['clock_bound']+1)
    provenance = dict(prompt='Compare TLA+ queue actors with and without irrelevant internal state.',
                      question='How many distinct states does TLC enumerate for the same order protocol?',
                      event_source='Pinned TLC 1.7.4 exhaustive safety-check logs for OrderQueue.tla and four finite configurations',
                      reducer='parse final distinct-state counts; verify independent cache/clock product factors',
                      unit='distinct model states', boundary='one client, one server, two order IDs, FIFO capacity two; no liveness or refinement proof',
                      tool_sha256=EXPECTED, model_sha256=hashlib.sha256((MODEL/'OrderQueue.tla').read_bytes()).hexdigest())
    (ROOT/'book/generated/tla-state-space.json').write_text(json.dumps(dict(provenance=provenance, runs=rows), indent=2)+'\n')
    table = ['% Generated from TLC logs by scripts/check_tla_example.py.',
             r'\begin{tabular}{@{}lrrr@{}}\toprule',
             r'Model & Cache bits & Clock bound & Distinct states \\\midrule']
    table += [f"{r['config']} & {r['cache_bits']} & {r['clock_bound']} & {r['distinct']:,} \\\\" for r in rows]
    table += [r'\bottomrule\end{tabular}']
    (ROOT/'book/generated/tla-state-space.tex').write_text('\n'.join(table)+'\n')
    print('ok: TLC safety checks and independent-state multiplication:', [(r['config'],r['distinct']) for r in rows])

if __name__ == '__main__':
    main()
