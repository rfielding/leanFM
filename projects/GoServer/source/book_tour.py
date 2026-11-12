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
          'source/cmd/demo/static/index.html', 'source/web/src/ui/App.tsx', 'source/web/src/ui/Room.tsx', 'source/web/src/ui/Game.tsx',
          'source/web/src/ui/Panels.tsx', 'source/web/src/ui/Board.tsx', 'source/web/src/game/game.ts', 'source/web/src/styles.css', 'source/cmd/demo/static/engine.js', 'source/book_tour.py']
WIDTH, HEIGHT = 1500, 1150
A = '.room-panel:not([hidden])'           # the room tab being shown
G = A + ' .game-panel:not([hidden])'  # the game tab being shown in it


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
        self.wait("!!document.querySelector('.session-form')")

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
        # React tracks values it set itself; use the native setter so the change event counts.
        self.js(f"(()=>{{const e=document.querySelector({json.dumps(sel)});Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(e,{json.dumps(value)});e.dispatchEvent(new Event('change',{{bubbles:true}}));}})()")

    def board_point(self, x, y):
        self.js("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board').scrollIntoView({block:'center'})")
        time.sleep(.15)
        r = self.js("(()=>{const r=document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board').getBoundingClientRect();return [r.left,r.top,r.width]})()")
        n = self.js("GameViewDebug.size()")
        cell = r[2] / (n + 2)
        return r[0] + cell * 1.5 + x * cell, r[1] + cell * 1.5 + y * cell

    def board_hover(self, x, y):
        """Move the mouse over board point (x, y) without clicking."""
        px, py = self.board_point(x, y)
        self.b.call('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': px, 'y': py, 'button': 'none'}, self.s)
        time.sleep(.1)

    def board_pixel(self, x, y):
        """RGBA of the board canvas at the centre of point (x, y)."""
        return self.js(f"(()=>{{const c=document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board'),n=GameViewDebug.size(),cell=c.width/(n+2);"
                       f"return Array.from(c.getContext('2d').getImageData(Math.round(cell*1.5+{x}*cell),Math.round(cell*1.5+{y}*cell),1,1).data)}})()")

    def press(self, key):
        """A real key press, as from the keyboard (CDP key events, not a synthetic DOM event)."""
        named = {'Home': 36, 'End': 35, 'ArrowLeft': 37, 'ArrowUp': 38, 'ArrowRight': 39, 'ArrowDown': 40}
        for t in ('keyDown', 'keyUp'):
            if key in named:
                self.b.call('Input.dispatchKeyEvent', {'type': t, 'key': key, 'code': key, 'windowsVirtualKeyCode': named[key]}, self.s)
            else:
                self.b.call('Input.dispatchKeyEvent', {'type': t, 'key': key, 'text': key if t == 'keyDown' else '', 'code': 'Key' + key.upper(), 'windowsVirtualKeyCode': ord(key.upper())}, self.s)

    def tab(self, name):
        self.click(G + ' [role=tab][data-panel="' + name + '"]')
        self.wait(f"!!document.querySelector('{G} .tabpanel[data-panel=\"{name}\"]')")

    def board_click(self, x, y):
        """Click the board point (x, y) with real mouse events, as a person would."""
        self.js("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board').scrollIntoView({block:'center'})")
        time.sleep(.15)
        r = self.js("(()=>{const r=document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board').getBoundingClientRect();return [r.left,r.top,r.width]})()")
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
    server = subprocess.Popen([str(ROOT / '.cache/goserver')], env=dict(os.environ, PORT=str(PORT), GOSERVER_DATA_DIR=str(ROOT / '.cache/tour-data')), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
            p.js(f"document.querySelector('.identity').value={json.dumps(p.name)};document.querySelector('.session-form').requestSubmit()")
            p.wait("(document.querySelector('.room-panel[data-room=\\'lobby\\'] .room-state')||{}).textContent==='Joined'")

        alice = Person(browser, 'alice')
        capture(alice, '01-welcome', 'Welcome', 'A visitor chooses a local display name. Nothing else is needed for the local preview.',
                ['open the app'], clip={'x': 0, 'y': 0, 'width': WIDTH, 'height': 520})
        sign_in(alice)
        alice.js("document.querySelector('.room-panel:not([hidden]) .challenge-form input[name=name]').value='Evening three-way'")
        for sel, v in [('.room-panel:not([hidden]) select[name=board]', '9'), ('.room-panel:not([hidden]) select[name=seats]', '3'), ('.room-panel:not([hidden]) select[name=main]', '60000'), ('.room-panel:not([hidden]) select[name=periods]', '3'), ('.room-panel:not([hidden]) select[name=period]', '10000')]:
            alice.select(sel, v)
        capture(alice, '02-create-challenge', 'Creating a challenge',
                'Alice is in the lobby and fills in a challenge: a 9×9 board, three players, and a byo-yomi clock of one minute of main time and then three periods of ten seconds, the same for people and bots. The ko rule stays on Auto, which is off for three players.',
                ['sign in as alice', 'fill in the New challenge form'], clip={'x': 0, 'y': 60, 'width': WIDTH, 'height': 1000})
        alice.js("document.querySelector('.room-panel:not([hidden]) .challenge-form').requestSubmit()")
        alice.wait("!!document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .rrow[data-seat=\"3\"] .plan-ctl')")
        alice.select('.room-panel:not([hidden]) .game-panel:not([hidden]) .rrow[data-seat="3"] .plan-ctl', 'bot')
        alice.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .roster')||{textContent:''}).textContent.includes('Bot')")
        bob, carol = Person(browser, 'bob'), Person(browser, 'carol')
        for p in (bob, carol):
            sign_in(p)
            p.wait("!!document.querySelector('.room-panel:not([hidden]) .challenge-card button')")
            p.click('.room-panel:not([hidden]) .challenge-card button')
            p.wait("!!(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .roster')||{children:[]}).children.length")
        bob.wait("Array.from(document.querySelectorAll('.room-panel:not([hidden]) .game-panel:not([hidden]) .roster button')).some(b=>b.textContent==='Sit here')")
        bob.click_text('.room-panel:not([hidden]) .game-panel:not([hidden]) .roster button', 'Sit here')
        alice.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .roster')||{textContent:''}).textContent.includes('bob')")
        capture(alice, '03-seat-plan', 'Planning seats',
                'Before the start the creator decides, seat by seat, whether a person or a bot plays and which team the seat is on. Alice took seat 1, bob sat in seat 2, and alice marked seat 3 as a bot.',
                ['alice: create the challenge (seated automatically)', 'alice: set seat 3 to Bot', 'bob: open the challenge, Sit here'], scroll_to=G)
        alice.click(G + ' .gv-start')
        moves = [('alice', 4, 4), ('bob', 2, 6), ('alice', 6, 2), ('bob', 6, 6)]
        people = {'alice': alice, 'bob': bob}
        for who, x, y in moves:
            p = people[who]
            p.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .status')||{textContent:''}).textContent.includes('your move')", 30)
            p.board_click(x, y)
            p.wait("!(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .status')||{textContent:''}).textContent.includes('your move')", 10)
        alice.wait("GameViewDebug.liveMove()>=6", 30)
        alice.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .status')||{textContent:''}).textContent.includes('your move')", 30)
        # the pointer preview: a translucent stone where a click would play, nothing over an occupied point
        pts = [(x, y) for y in range(9) for x in range(9)]
        empty = next(q for q in pts if alice.js(f'GameViewDebug.point({q[0]},{q[1]})') == 0 and abs(q[0]-4) + abs(q[1]-4) <= 3)
        taken = next(q for q in pts if alice.js(f'GameViewDebug.point({q[0]},{q[1]})') > 0)
        before = alice.board_pixel(*empty)
        alice.board_hover(*empty)
        after = alice.board_pixel(*empty)
        if before == after or alice.js("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board').style.cursor") != 'pointer':
            raise RuntimeError('no stone preview under the pointer on an empty point during my turn')
        capture(alice, '04a-aim', 'Aiming a stone',
                'On her turn alice moves the pointer over the board: a translucent stone in her colour shows exactly where a click will play. Over an occupied point, a point the ko rule forbids, or when it is not her turn, there is no preview and the pointer shows that a click would be refused. Above the tabs, the play bar keeps whose turn it is and the clock in view.',
                ['alice: move the pointer over an empty point on her turn'], scroll_to=G)
        before = alice.board_pixel(*taken)
        alice.board_hover(*taken)
        if alice.board_pixel(*taken) != before or alice.js("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board').style.cursor") != 'not-allowed':
            raise RuntimeError('a stone preview appeared over an occupied point')
        alice.tab('search')
        alice.js("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .nav-back').click()")
        capture(alice, '04-bot-search', 'Reading the bot\u2019s search',
                'Alice steps back one move, to the position where the bot searched for its last move. The panel lists the moves that search weighed, with visit share and expected reward; the blue discs on the board are the same search as a heat map. Proj. and Outlook give every seat\u2019s projected final score and expected reward, and the timeline under them plots the projections move by move.',
                ['alice and bob alternate stones by clicking the board; the bot answers each round', 'alice: Back one move'], scroll_to=G)
        alice.click(G + ' .nav-live')
        carol.wait("GameViewDebug.liveMove()>=6", 20)
        carol.js("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .nav-home').click()")
        for _ in range(3):
            carol.js("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .nav-fwd').click()")
        carol.board_click(7, 1)
        carol.tab('search')
        carol.click(G + ' .gv-analyze')
        carol.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .gv-think')||{textContent:''}).textContent.includes('Your local search')")
        time.sleep(.35)
        capture(carol, '05-watcher-variation', 'A watcher explores a variation',
                'Carol is watching, not playing. She steps back to move 3, tries a different stone (the gold ring marks a variation), and asks for a local search. The analysis runs in her browser only: the dashed branch in the tree never reaches the server, and the live game continues.',
                ['carol: open the challenge as a watcher', 'carol: Home, then Forward three times', 'carol: click an empty point', 'carol: Analyze here'], scroll_to=G)
        carol.wait("!(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .gv-think')||{textContent:''}).textContent.includes('Your local search')", 20)
        carol.click(G + ' .nav-live')
        bob.wait("!!document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .merges button')")
        bob.click_text('.room-panel:not([hidden]) .game-panel:not([hidden]) .merges button', 'Propose')
        alice.wait("!!document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) [role=tab][data-panel=\"seats\"] .badge')")  # the Seats tab flags a merge awaiting her answer
        alice.tab('seats')
        alice.wait("Array.from(document.querySelectorAll('.room-panel:not([hidden]) .game-panel:not([hidden]) .merges button')).some(b=>b.textContent==='Accept merge')")
        capture(alice, '06-merge-proposal', 'Proposing a team merge',
                'During play bob proposes merging his team with alice\u2019s. The Seats tab flags a proposal waiting for her answer; there the proposal shows who has accepted and who is still to answer; it takes effect only when every person on both teams accepts, and it is permanent.',
                ['bob: Merge my team with Team 1, Propose'], scroll_to='.room-panel:not([hidden]) .game-panel:not([hidden]) .roster')
        alice.click_text('.room-panel:not([hidden]) .game-panel:not([hidden]) .merges button', 'Accept merge')
        alice.tab('scores')
        alice.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .scores')||{textContent:''}).textContent.includes('Team totals')")
        alice.click(G + ' .gv-autopilot')
        alice.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .gv-autopilot')||{textContent:''}).textContent.includes('Take my seat back')")
        alice.wait("GameViewDebug.lastSource()==='autopilot'", 30)
        capture(alice, '07-team-and-autopilot', 'Playing as a team, on autopilot',
                'After the merge the score table shows alice and bob as team 1 with a combined total. Alice then lets a bot play her seat; the seat, team and name stay hers, and the bot\u2019s move publishes its search like any other bot move. She can take the seat back at any time.',
                ['alice: Accept merge', 'alice: Let a bot play for me'], scroll_to=G)
        alice.click(G + ' .gv-autopilot')
        alice.wait("(document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .gv-autopilot')||{textContent:''}).textContent.includes('Let a bot play')")
        MY_TURN = "(document.querySelector('" + G + " .status')||{textContent:''}).textContent.includes('your move') && !document.querySelector('" + G + " .gv-pass').disabled"
        pressed_once = False
        ends_by = time.monotonic() + 600  # people pass; the bot plays on its byo-yomi clock until it passes too
        while time.monotonic() < ends_by:
            if alice.js("GameViewDebug.status()") == 'finished':
                break
            for p in (alice, bob):
                if p.js(MY_TURN):
                    if p is alice:  # alice passes with the P key while a tab button has focus
                        alice.js("document.querySelector('" + G + " [role=tab][aria-selected=true]').focus()")
                        alice.press('p')
                        if not pressed_once:
                            try:  # a board update may race the key press; the loop presses again
                                alice.wait("!(" + MY_TURN + ")", 8)
                                pressed_once = True
                            except RuntimeError:
                                pass
                    else:
                        p.click(G + ' .gv-pass')
            time.sleep(.4)
        alice.wait("GameViewDebug.status()==='finished'", 120)
        alice.wait("!!document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) [role=tab][data-panel=\"chat\"] .badge')", 10)  # unread announcement on the Chat tab
        alice.tab('chat')
        alice.wait("document.querySelector('.room-panel:not([hidden]) .game-panel:not([hidden]) .game-chat').textContent.includes('Game over')", 10)
        capture(alice, '08-game-over', 'The result',
                'When every remaining player has passed in a row the game ends. The Chat tab lights up with an unread count; the server announces team scores and the winners in the game conversation. Everyone, players included, can now branch and analyse any position.',
                ['alice passes with the P key, bob with the Pass button, until the bot also passes'], scroll_to=G)
        # After the end every player's moves are open to analysis: step back, pass with P for
        # whoever was to move there, then let the computer choose the next seat's move with C.
        alice.js("document.activeElement && document.activeElement.blur()")
        alice.press('Home')
        alice.wait("(document.querySelector('" + G + " .status')||{textContent:''}).textContent.includes('Empty board')")
        alice.press('ArrowRight'); alice.press('ArrowRight')
        alice.wait("!!document.querySelector('" + G + " .gv-pass:not([disabled])')")
        alice.press('p')
        alice.wait("(document.querySelector('" + G + " .status')||{textContent:''}).textContent.includes('not part of the game') && document.querySelector('" + G + " .status').textContent.includes('Move 3')")
        alice.press('c')
        alice.wait("(document.querySelector('" + G + " .status')||{textContent:''}).textContent.includes('Move 4') && document.querySelector('" + G + " .status').textContent.includes('not part of the game')", 20)
        # The moves after the finish are kept for everyone in the game; a remark sticks to its position.
        alice.wait("GameViewDebug.reviewCount() >= 2 && GameViewDebug.curRef().startsWith('r')", 10)
        alice.tab('chat')
        alice.wait("!!document.querySelector('" + G + " .game-chat-form fieldset:not([disabled])')")
        alice.js("document.querySelector('" + G + " .game-chat-form input').value='this was the losing move';document.querySelector('" + G + " .game-chat-form').requestSubmit()")
        alice.wait("Array.from(document.querySelectorAll('" + G + " .game-chat .chat-item')).some(i => i.textContent.includes('this was the losing move') && i.textContent.includes('here'))")
        capture(alice, '08a-review-chat', 'Reviewing together',
                'After the game alice steps back to move 2, passes for the seat to move there and lets the computer pick the next move. Both moves are kept on the server for everyone in the game, and her remark is pinned to the position she was looking at: the Chat tab shows the remarks along the line on the board, so stepping back hides it again and anyone who walks into this variation sees it.',
                ['alice: Home, then → twice', 'alice: P, then C', 'alice: write a remark in Chat'], scroll_to=G)
        here = alice.js("GameViewDebug.curRef()")
        alice.js("document.activeElement && document.activeElement.blur()")
        alice.press('Home')
        alice.wait("!Array.from(document.querySelectorAll('" + G + " .game-chat .chat-item')).some(i => i.textContent.includes('this was the losing move'))")
        bob.b.call('Page.reload', {}, bob.s)
        # tabs survive the reload; the room opens on its Lobby, so bob opens the game's tab again
        bob.wait("!!document.querySelector('.room-panel:not([hidden]) .game-tabs [role=tab]:not([data-game=\"__lobby\"])')", 20)
        bob.js("document.querySelector('.room-panel:not([hidden]) .game-tabs [role=tab]:not([data-game=\"__lobby\"])').click()")
        bob.wait("window.GameViewDebug && GameViewDebug.reviewCount() >= 2", 20)
        bob.js("GameViewDebug.goRef(" + json.dumps(here) + ")")
        bob.tab('chat')
        bob.wait("Array.from(document.querySelectorAll('" + G + " .game-chat .chat-item')).some(i => i.textContent.includes('this was the losing move'))", 20)
        # ↑/↓ choose among the next moves when there are several (the game's move and the review's)
        alice.js("document.activeElement && document.activeElement.blur()")
        alice.press('Home')
        for _ in range(12):  # walk the game forward to the first position with two next moves
            time.sleep(.15)
            if alice.js("document.querySelectorAll('" + G + " .chips .chip').length") >= 2:
                break
            alice.press('ArrowRight')
        alice.wait("document.querySelectorAll('" + G + " .chips .chip').length >= 2")
        depth = alice.js("+((document.querySelector('" + G + " .status').textContent.match(/Move (\\d+)/)||[0,0])[1])")
        first = alice.js("document.querySelector('" + G + " .chips .chip.main').textContent.trim()[0]")
        alice.press('ArrowDown')
        alice.wait("document.querySelector('" + G + " .chips .chip.main').textContent.trim()[0] !== " + json.dumps(first))
        chosen = alice.js("document.querySelector('" + G + " .chips .chip.main').textContent.trim()")
        alice.press('ArrowRight')
        alice.wait("(document.querySelector('" + G + " .status')||{textContent:''}).textContent.includes('Move " + str(depth + 1) + "')")
        alice.press('ArrowLeft'); alice.press('ArrowUp')
        alice.wait("document.querySelector('" + G + " .chips .chip.main').textContent.trim()[0] === " + json.dumps(first))
        alice.press('l')
        # rooms and games are tabs: open a second room, then come back to the game's room
        alice.click('[role=tab][data-room="__rooms"]')
        alice.wait("!!document.querySelector('.room-form')")
        alice.js("document.querySelector('.room-name').value='Post-game';document.querySelector('.room-form').requestSubmit()")
        alice.wait("(document.querySelector('.room-panel[data-room=\\'Post-game\\'] .room-state')||{}).textContent==='Joined'")
        alice.click('[role=tab][data-room="lobby"]')
        alice.wait("!!document.querySelector('" + G + "')")
        alice.js("window.scrollTo(0,0)")
        time.sleep(.3)
        capture(alice, '09-tabs', 'Rooms and games as tabs',
                'Every room alice has open is a tab along the top, with + Rooms for finding and creating rooms; inside a room, the Lobby (its conversation and challenge list) comes first and every open game has its own tab. Tabs stay alive in the background: a game keeps its variations and analysis, and a tab shows a badge when a move or a merge waits for her or messages arrive. Responses only ever land in the tab that asked for them.',
                ['alice: + Rooms, create Post-game', 'alice: back to the lobby room tab'], clip={'x': 0, 'y': 0, 'width': WIDTH, 'height': 560})
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
