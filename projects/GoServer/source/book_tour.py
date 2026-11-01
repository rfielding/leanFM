#!/usr/bin/env python3
"""Reproducible usage-scenario screenshots for the GoServer book.

Requirement refs: property:Lab-style viewer; property:Analysis is local; task:game_lifecycle;
task:team_merge; property:set_autopilot keeps the seat; output:game.score_timeline.

Drives the real application with several people in headless Chrome over the DevTools protocol
(the same mechanism as browser_check.py), captures named screenshots and writes
book/assets/tour/manifest.json binding each image to its scenario step, viewer, source hashes
and browser version. book/main.tex includes the images in the chapter "Usage scenarios".

Run from source/:  make book-tour   (or: python3 book_tour.py)
Environment: CHROME (default google-chrome), TOUR_PORT (default 8095, never LeanFM's 8080).
Needs the websocket-client Python package, like browser_check.py.
"""
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import websocket

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'book/assets/tour'
PORT = int(os.environ.get('TOUR_PORT', '8095'))
BASE = f'http://127.0.0.1:{PORT}/'
CHROME = os.environ.get('CHROME', 'google-chrome')
PROMPT = 'In the book, using the LeanFM server, take screenshots that show actual usage scenarios.'
INPUTS = ['source/game.go', 'source/engine.go', 'source/bot.go', 'source/server.go', 'source/cmd/demo/main.go',
          'source/cmd/demo/static/index.html', 'source/cmd/demo/static/app.js', 'source/cmd/demo/static/gameview.js',
          'source/cmd/demo/static/style.css', 'source/cmd/demo/static/engine.js', 'source/book_tour.py']
WIDTH, HEIGHT = 1500, 1150


class Browser:
    def __init__(self):
        self.profile = tempfile.mkdtemp(prefix='goserver-tour-')
        self.proc = subprocess.Popen([CHROME, '--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
                                      '--no-first-run', '--disable-background-networking', '--force-color-profile=srgb',
                                      '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
                                      '--remote-allow-origins=http://127.0.0.1', '--user-data-dir=' + self.profile, 'about:blank'],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        port_file = Path(self.profile) / 'DevToolsActivePort'
        deadline = time.monotonic() + 20
        while not port_file.exists():
            if time.monotonic() > deadline or self.proc.poll() is not None:
                raise RuntimeError('Chrome did not start; set CHROME to a Chrome or Chromium binary')
            time.sleep(.05)
        port = port_file.read_text().splitlines()[0]
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/json/version') as r:
            info = json.load(r)
        self.version = info['Browser']
        self.ws = websocket.create_connection(info['webSocketDebuggerUrl'], origin='http://127.0.0.1', timeout=30)
        self.seq = 0
        self.errors = []

    def call(self, method, params=None, session=None):
        self.seq += 1
        msg = {'id': self.seq, 'method': method, 'params': params or {}}
        if session:
            msg['sessionId'] = session
        self.ws.send(json.dumps(msg))
        while True:
            r = json.loads(self.ws.recv())
            if r.get('method') == 'Runtime.exceptionThrown':
                self.errors.append(r['params']['exceptionDetails'].get('text', 'exception'))
            if r.get('id') == self.seq:
                if 'error' in r:
                    raise RuntimeError(r['error'])
                return r.get('result', {})

    def close(self):
        try:
            self.ws.close()
        finally:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class Person:
    """One viewer in its own browser context (separate sessionStorage, like a separate person)."""

    def __init__(self, browser, name):
        self.b, self.name = browser, name
        ctx = browser.call('Target.createBrowserContext')['browserContextId']
        target = browser.call('Target.createTarget', {'url': 'about:blank', 'browserContextId': ctx})['targetId']
        self.s = browser.call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
        for m in ('Runtime.enable', 'Page.enable'):
            browser.call(m, session=self.s)
        browser.call('Emulation.setDeviceMetricsOverride', {'width': WIDTH, 'height': HEIGHT, 'deviceScaleFactor': 1, 'mobile': False}, self.s)
        browser.call('Emulation.setEmulatedMedia', {'features': [{'name': 'prefers-color-scheme', 'value': 'dark'}, {'name': 'prefers-reduced-motion', 'value': 'reduce'}]}, self.s)
        browser.call('Page.navigate', {'url': BASE}, self.s)
        self.wait("typeof openRoom==='function' && typeof GameView==='object'")

    def js(self, expr):
        r = self.b.call('Runtime.evaluate', {'expression': expr, 'awaitPromise': True, 'returnByValue': True}, self.s)
        if 'exceptionDetails' in r:
            raise RuntimeError(self.name + ': ' + r['exceptionDetails'].get('text', 'exception') + ' in ' + expr[:120])
        return r.get('result', {}).get('value')

    def wait(self, expr, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.js(expr):
                return
            time.sleep(.08)
        raise RuntimeError(self.name + ' timed out waiting for: ' + expr)

    def text(self, sel):
        return self.js(f"(document.querySelector({json.dumps(sel)})||{{}}).textContent||''")

    def click(self, sel):
        self.js(f"document.querySelector({json.dumps(sel)}).click()")

    def click_text(self, sel, text):
        self.js(f"Array.from(document.querySelectorAll({json.dumps(sel)})).find(e=>e.textContent.includes({json.dumps(text)})).click()")

    def select(self, sel, value):
        self.js(f"(()=>{{const e=document.querySelector({json.dumps(sel)});e.value={json.dumps(value)};e.dispatchEvent(new Event('change',{{bubbles:true}}));}})()")

    def board_click(self, x, y):
        """Click the board point (x, y) with real mouse events, as a person would."""
        self.js("document.getElementById('board').scrollIntoView({block:'center'})")
        time.sleep(.15)
        r = self.js("(()=>{const r=document.getElementById('board').getBoundingClientRect();return [r.left,r.top,r.width]})()")
        n = self.js("GameViewDebug.size()")
        cell = r[2] / (n + 2)
        px, py = r[0] + cell * 1.5 + x * cell, r[1] + cell * 1.5 + y * cell
        for t in ('mousePressed', 'mouseReleased'):
            self.b.call('Input.dispatchMouseEvent', {'type': t, 'x': px, 'y': py, 'button': 'left', 'clickCount': 1}, self.s)

    def shot(self, scroll_to=None, clip=None):
        if scroll_to:
            self.js(f"document.querySelector({json.dumps(scroll_to)}).scrollIntoView({{block:'start'}})")
            time.sleep(.3)
        params = {'format': 'png'}
        if clip:
            params['clip'] = dict(clip, scale=1)
        return base64.b64decode(self.b.call('Page.captureScreenshot', params, self.s)['data'])


def sha(p):
    return hashlib.sha256((ROOT / p).read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['make', 'build'], cwd=ROOT / 'source', check=True, stdout=subprocess.DEVNULL)
    server = subprocess.Popen([str(ROOT / '.cache/goserver')], env=dict(os.environ, PORT=str(PORT)), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    browser = None
    captures = []
    try:
        deadline = time.monotonic() + 20
        while True:
            try:
                with urllib.request.urlopen(BASE + 'health', timeout=.5) as r:
                    if r.status == 200:
                        break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError('app did not become ready on ' + BASE)
                time.sleep(.1)
        browser = Browser()

        def capture(person, cid, title, caption, steps, **kw):
            png = person.shot(**kw)
            (OUT / (cid + '.png')).write_bytes(png)
            captures.append({'id': cid, 'title': title, 'caption': caption, 'viewer': person.name, 'steps': steps,
                             'file': f'book/assets/tour/{cid}.png', 'sha256': hashlib.sha256(png).hexdigest()})
            print('captured', cid)

        def sign_in(p):
            p.js(f"document.getElementById('identity').value={json.dumps(p.name)};document.getElementById('session-form').requestSubmit()")
            p.wait("document.getElementById('room-state').textContent==='Joined'")

        alice = Person(browser, 'alice')
        capture(alice, '01-welcome', 'Welcome', 'A visitor chooses a local display name. Nothing else is needed for the local preview.',
                ['open the app'], clip={'x': 0, 'y': 0, 'width': WIDTH, 'height': 520})
        sign_in(alice)
        alice.js("document.getElementById('challenge-name').value='Evening three-way'")
        for sel, v in [('#board-size', '9'), ('#seats', '3'), ('#turn-deadline', '60000'), ('#bot-time', '500')]:
            alice.select(sel, v)
        capture(alice, '02-create-challenge', 'Creating a challenge',
                'Alice is in the lobby and fills in a challenge: a 9×9 board, three players, a one-minute human deadline and half a second per bot move. The ko rule stays on Auto, which is off for three players.',
                ['sign in as alice', 'fill in the New challenge form'], clip={'x': 0, 'y': 60, 'width': WIDTH, 'height': 1000})
        alice.js("document.getElementById('challenge-form').requestSubmit()")
        alice.wait("!!document.getElementById('plan-ctl-3')")
        alice.select('#plan-ctl-3', 'bot')
        alice.wait("document.querySelector('#gv-seats').textContent.includes('Bot')")
        bob, carol = Person(browser, 'bob'), Person(browser, 'carol')
        for p in (bob, carol):
            sign_in(p)
            p.wait("!!document.querySelector('.challenge-card button')")
            p.click('.challenge-card button')
            p.wait("!!document.getElementById('gv-seats').children.length")
        bob.wait("Array.from(document.querySelectorAll('#gv-seats button')).some(b=>b.textContent==='Sit here')")
        bob.click_text('#gv-seats button', 'Sit here')
        alice.wait("document.querySelector('#gv-seats').textContent.includes('bob')")
        capture(alice, '03-seat-plan', 'Planning seats',
                'Before the start the creator decides, seat by seat, whether a person or a bot plays and which team the seat is on. Alice took seat 1, bob sat in seat 2, and alice marked seat 3 as a bot.',
                ['alice: create the challenge (seated automatically)', 'alice: set seat 3 to Bot', 'bob: open the challenge, Sit here'], scroll_to='#game-panel')
        alice.click('#gv-start')
        moves = [('alice', 4, 4), ('bob', 2, 6), ('alice', 6, 2), ('bob', 6, 6)]
        people = {'alice': alice, 'bob': bob}
        for who, x, y in moves:
            p = people[who]
            p.wait("document.getElementById('gv-status').textContent.includes('your move')", 30)
            p.board_click(x, y)
            p.wait("!document.getElementById('gv-status').textContent.includes('your move')", 10)
        alice.wait("GameViewDebug.liveMove()>=6", 30)
        alice.wait("document.getElementById('gv-status').textContent.includes('your move')", 30)
        alice.js("document.getElementById('nav-back').click()")
        capture(alice, '04-bot-search', 'Reading the bot\u2019s search',
                'Alice steps back one move, to the position where the bot searched for its last move. The panel lists the moves that search weighed, with visit share and expected reward; the blue discs on the board are the same search as a heat map. Proj. and Outlook give every seat\u2019s projected final score and expected reward, and the timeline under them plots the projections move by move.',
                ['alice and bob alternate stones by clicking the board; the bot answers each round', 'alice: Back one move'], scroll_to='#game-panel')
        alice.click('#nav-live')
        carol.wait("GameViewDebug.liveMove()>=6", 20)
        carol.js("document.getElementById('nav-home').click()")
        for _ in range(3):
            carol.js("document.getElementById('nav-fwd').click()")
        carol.board_click(7, 1)
        carol.click('#gv-analyze')
        carol.wait("document.getElementById('gv-think').textContent.includes('Your local search')")
        time.sleep(.35)
        capture(carol, '05-watcher-variation', 'A watcher explores a variation',
                'Carol is watching, not playing. She steps back to move 3, tries a different stone (the gold ring marks a variation), and asks for a local search. The analysis runs in her browser only: the dashed branch in the tree never reaches the server, and the live game continues.',
                ['carol: open the challenge as a watcher', 'carol: Home, then Forward three times', 'carol: click an empty point', 'carol: Analyze here'], scroll_to='#game-panel')
        carol.wait("!document.getElementById('gv-think').textContent.includes('Your local search')", 20)
        carol.click('#nav-live')
        bob.wait("!!document.querySelector('#gv-merges button')")
        bob.click_text('#gv-merges button', 'Propose')
        alice.wait("Array.from(document.querySelectorAll('#gv-merges button')).some(b=>b.textContent==='Accept merge')")
        capture(alice, '06-merge-proposal', 'Proposing a team merge',
                'During play bob proposes merging his team with alice\u2019s. The proposal shows who has accepted and who is still to answer; it takes effect only when every person on both teams accepts, and it is permanent.',
                ['bob: Merge my team with Team 1, Propose'], scroll_to='#gv-seats')
        alice.click_text('#gv-merges button', 'Accept merge')
        alice.wait("document.getElementById('gv-scores').textContent.includes('Team totals')")
        alice.click('#gv-autopilot')
        alice.wait("document.getElementById('gv-autopilot').textContent.includes('Take my seat back')")
        alice.wait("GameViewDebug.lastSource()==='autopilot'", 30)
        capture(alice, '07-team-and-autopilot', 'Playing as a team, on autopilot',
                'After the merge the score table shows alice and bob as team 1 with a combined total. Alice then lets a bot play her seat; the seat, team and name stay hers, and the bot\u2019s move publishes its search like any other bot move. She can take the seat back at any time.',
                ['alice: Accept merge', 'alice: Let a bot play for me'], scroll_to='#game-panel')
        alice.click('#gv-autopilot')
        alice.wait("document.getElementById('gv-autopilot').textContent.includes('Let a bot play')")
        for _ in range(700):  # people pass; the bot plays until it is content to pass too
            if alice.js("GameViewDebug.status()") == 'finished':
                break
            for p in (alice, bob):
                if p.js("document.getElementById('gv-status').textContent.includes('your move') && !document.getElementById('gv-pass').disabled"):
                    p.click('#gv-pass')
            time.sleep(.4)
        alice.wait("GameViewDebug.status()==='finished'", 60)
        alice.wait("document.getElementById('game-chat').textContent.includes('Game over')", 10)
        capture(alice, '08-game-over', 'The result',
                'When every remaining player has passed in a row the game ends. The server announces team scores and the winners in the game conversation. Everyone, players included, can now branch and analyse any position.',
                ['alice and bob pass until the bot also passes'], scroll_to='#game-panel')
        errors = browser.errors
        if errors:
            raise RuntimeError('browser errors: ' + '; '.join(errors))
        manifest = {'prompt': PROMPT,
                    'question': 'What does a real session look like for players, the creator and a watcher?',
                    'event_source': 'the running GoServer application driven by scripted people in headless Chrome',
                    'reducer': 'named DevTools screenshots after each scripted step', 'unit': 'one screenshot per scenario step',
                    'boundary': 'local loopback app on port %d; in-memory state discarded afterwards; no credentials shown' % PORT,
                    'browser': browser.version, 'created': datetime.now(timezone.utc).isoformat(timespec='seconds'),
                    'inputs': {p: sha(p) for p in INPUTS}, 'captures': captures,
                    'note': 'Bot moves come from a time-limited search, so stone positions differ between runs; the scenario steps do not.'}
        (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
        write_tex(captures)
        print('ok: %d screenshots in book/assets/tour; chapter source book/tour.tex' % len(captures))
    finally:
        if browser:
            browser.close()
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()


def tex(s):
    for a, b in [('\\', '\\textbackslash{}'), ('&', '\\&'), ('%', '\\%'), ('#', '\\#'), ('_', '\\_'), ('×', '$\\times$'), ('\u2019', "'"), ('\u2014', '---')]:
        s = s.replace(a, b)
    return s


def write_tex(captures):
    lines = ['% Generated by source/book_tour.py; do not edit by hand.',
             '\\chapter{Usage scenarios}', '\\label{ch:usage}',
             'These screenshots come from the running application, driven by a script that plays the parts of three people: alice creates the challenge, bob joins her, and carol watches. '
             '\\texttt{make tour} in the project root reproduces them; \\path{book/assets/tour/manifest.json} records each step, viewer, image hash, source hashes and browser version. '
             'Bot moves come from a time-limited search, so the stones differ between runs while the steps do not.', '']
    for c in captures:
        lines += ['\\section{' + tex(c['title']) + '}', tex(c['caption']), '',
                  '\\begin{figure}[ht]', '\\centering', '\\includegraphics[width=\\textwidth]{assets/tour/' + c['id'] + '.png}',
                  '\\caption{' + tex(c['title']) + ', seen by ' + c['viewer'] + '. Steps: ' + tex('; '.join(c['steps'])) + '.}', '\\end{figure}', '\\clearpage', '']
    (ROOT / 'book/tour.tex').write_text('\n'.join(lines))


if __name__ == '__main__':
    main()
