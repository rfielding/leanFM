"""Play two real GoServer games at once in headless Chrome and keep what happened: four people on an
11x11 board and three on a 9x9, every person in a browser context of their own (as separate people),
each clicking a legal point on their turn. The board of each game is captured after every move, and
every browser's API traffic (each request and its response, with wall-clock times) is recorded by a
fetch wrapper in the page. Writes build/frames/<game>/NNN.png and data/traffic.json.

Run from the LeanFM root: python3 video/goserver/play.py   (Chrome, the websocket-client package, and
GoServer built with make -C projects/GoServer/source build). Port 8096, never LeanFM's 8080."""
import base64, json, os, random, subprocess, sys, time, urllib.request
from pathlib import Path

D = Path(__file__).resolve().parent
ROOT = D.parents[1]
sys.path.insert(0, str(ROOT / "projects/GoServer/source"))
import book_tour as bt  # the tour's Browser and Person: the same DevTools mechanism

PORT = 8096
bt.BASE = f"http://127.0.0.1:{PORT}/"
FRAMES = D / "build/frames"
DATA = D / "data"
random.seed(11)

# a fetch wrapper in every page: each API call and its answer, with wall-clock milliseconds
WRAP = r"""(() => {
  const real = window.fetch.bind(window); window.__traffic = [];
  window.fetch = async (url, opts) => {
    const u = String(url), sent = Date.now();
    const r = await real(url, opts);
    if (u.includes('api/')) {
      let req = null, res = null;
      try { req = JSON.parse((opts && opts.body) || 'null'); } catch (e) {}
      try { res = await r.clone().json(); } catch (e) {}
      window.__traffic.push({route: u.replace(/^.*api\//, '/api/'), sent, received: Date.now(), status: r.status, req, res});
    }
    return r;
  };
})();"""

G = bt.G
STATUS = f"(document.querySelector('{G} .status')||{{textContent:''}}).textContent"

def person(browser, name):
    p = bt.Person.__new__(bt.Person)
    p.b, p.name = browser, name
    ctx = browser.call("Target.createBrowserContext")["browserContextId"]
    target = browser.call("Target.createTarget", {"url": "about:blank", "browserContextId": ctx})["targetId"]
    p.s = browser.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
    for m in ("Runtime.enable", "Page.enable"):
        browser.call(m, session=p.s)
    browser.call("Page.addScriptToEvaluateOnNewDocument", {"source": WRAP}, p.s)
    browser.call("Emulation.setDeviceMetricsOverride", {"width": 1500, "height": 1150, "deviceScaleFactor": 1, "mobile": False}, p.s)
    browser.call("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}, {"name": "prefers-reduced-motion", "value": "reduce"}]}, p.s)
    browser.call("Page.navigate", {"url": bt.BASE}, p.s)
    p.wait("!!document.querySelector('.session-form')")
    p.js(f"document.querySelector('.identity').value={json.dumps(name)};document.querySelector('.session-form').requestSubmit()")
    p.wait("(document.querySelector('.room-panel[data-room=\\'lobby\\'] .room-state')||{}).textContent==='Joined'")
    return p

def create(p, title, board, seats):
    p.js(f"document.querySelector('.room-panel:not([hidden]) .challenge-form input[name=name]').value={json.dumps(title)}")
    for sel, v in [("board", str(board)), ("seats", str(seats)), ("main", "300000"), ("periods", "5"), ("period", "30000")]:
        p.select(f".room-panel:not([hidden]) select[name={sel}]", v)
    p.js("document.querySelector('.room-panel:not([hidden]) .challenge-form').requestSubmit()")
    p.wait(f"!!document.querySelector('{G} canvas.board')")

def join(p, title):
    find = f"Array.from(document.querySelectorAll('.room-panel:not([hidden]) .challenge-card')).find(c=>c.textContent.includes({json.dumps(title)}))"
    p.wait(f"!!({find}||null)")
    p.js(f"{find}.querySelector('button').click()")
    p.wait(f"Array.from(document.querySelectorAll('{G} .roster button')).some(b=>b.textContent==='Sit here')")
    p.click_text(f"{G} .roster button", "Sit here")
    p.wait(f"(document.querySelector('{G} .roster')||{{textContent:''}}).textContent.includes({json.dumps(p.name)})")

def board_shot(p):
    p.js(f"document.querySelector('{G} canvas.board').scrollIntoView({{block:'center'}})")
    # the clip is in page coordinates: the canvas's place in the viewport plus the scroll
    r = p.js(f"(()=>{{const r=document.querySelector('{G} canvas.board').getBoundingClientRect();return [r.left+window.scrollX,r.top+window.scrollY,r.width,r.height]}})()")
    clip = {"x": max(0, r[0] - 8), "y": max(0, r[1] - 8), "width": r[2] + 16, "height": r[3] + 16, "scale": 1}
    return base64.b64decode(p.b.call("Page.captureScreenshot", {"format": "png", "clip": clip}, p.s)["data"])

def play_one(p, n):
    """Click a legal empty point, preferring points near the stones already down, as people do."""
    stones = [(x, y) for y in range(n) for x in range(n) if p.js(f"GameViewDebug.point({x},{y})") > 0]
    empty = [(x, y) for y in range(n) for x in range(n) if p.js(f"GameViewDebug.point({x},{y})") == 0]
    def near(q): return min([abs(q[0] - s[0]) + abs(q[1] - s[1]) for s in stones] or [abs(q[0] - n // 2) + abs(q[1] - n // 2)])
    random.shuffle(empty); empty.sort(key=lambda q: near(q) if near(q) >= 1 else 9)
    before = p.js("GameViewDebug.liveMove()")
    for q in empty[:12]:
        p.board_click(*q)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if p.js("GameViewDebug.liveMove()") > before: return True
            time.sleep(.08)
    return False

def scrub(traffic):
    """Session tokens are credentials: each distinct one becomes s1, s2, ... (equal stay equal), wherever
    it appears, so no token is ever saved."""
    alias = {}
    def name(v): return alias.setdefault(v, f"s{len(alias) + 1}")
    for ts in traffic.values():
        for t in ts:
            for part in ("req", "res"):
                o = t.get(part)
                if isinstance(o, dict):
                    for k in ("sessionId", "session"):
                        if isinstance(o.get(k), str): o[k] = name(o[k])

def main():
    FRAMES.mkdir(parents=True, exist_ok=True); DATA.mkdir(parents=True, exist_ok=True)
    subprocess.run(["make", "build"], cwd=ROOT / "projects/GoServer/source", check=True, stdout=subprocess.DEVNULL)
    data_dir = ROOT / "projects/GoServer/.cache/video-play"
    server = subprocess.Popen([str(ROOT / "projects/GoServer/.cache/goserver")], env=dict(os.environ, PORT=str(PORT), GOSERVER_DATA_DIR=str(data_dir)),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    browser = None
    try:
        for _ in range(200):
            try:
                if urllib.request.urlopen(bt.BASE + "health", timeout=.5).status == 200: break
            except OSError: time.sleep(.1)
        browser = bt.Browser()
        games = {"eleven": {"title": "Four on eleven", "board": 11, "names": ["ana", "ben", "cy", "dee"], "moves": 44},
                 "nine": {"title": "Three on nine", "board": 9, "names": ["eve", "finn", "gus"], "moves": 30}}
        people = {}
        for key, g in games.items():
            ps = [person(browser, nm) for nm in g["names"]]
            create(ps[0], g["title"], g["board"], len(ps))
            for p in ps[1:]: join(p, g["title"])
            ps[0].click(f"{G} .gv-start")
            ps[0].wait("GameViewDebug.liveMove()>=0")
            g["people"] = ps; people.update({p.name: p for p in ps})
            (FRAMES / key).mkdir(parents=True, exist_ok=True)
        counts = {k: 0 for k in games}; frame = {k: 0 for k in games}
        for k, g in games.items():
            (FRAMES / k / f"{frame[k]:03d}.png").write_bytes(board_shot(g["people"][0])); frame[k] += 1
        stalls = 0
        while any(counts[k] < g["moves"] for k, g in games.items()) and stalls < 200:
            moved = False
            for k, g in games.items():
                if counts[k] >= g["moves"]: continue
                for p in g["people"]:
                    if "your move" in p.js(STATUS):
                        if play_one(p, g["board"]):
                            counts[k] += 1; moved = True
                            (FRAMES / k / f"{frame[k]:03d}.png").write_bytes(board_shot(g["people"][0])); frame[k] += 1
                        break
            stalls = 0 if moved else stalls + 1
            if not moved: time.sleep(.15)
        print("moves played:", counts, "frames:", frame)
        traffic = {}
        for name, p in people.items():
            traffic[name] = p.js("window.__traffic")
        scrub(traffic)
        json.dump({"games": {k: {"title": g["title"], "board": g["board"], "people": g["names"], "moves": counts[k]} for k, g in games.items()},
                   "traffic": traffic}, open(DATA / "traffic.json", "w"))
        print("requests recorded:", {n: len(t) for n, t in traffic.items()})
    finally:
        if browser: browser.close()
        server.terminate()

if __name__ == "__main__":
    main()
