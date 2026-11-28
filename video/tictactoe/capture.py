"""Capture the TicTacToe walkthrough, for real: LeanFM's introduction, the TicTacToe protocol's
requirements list, diagram and animation in LeanFM's own viewer (the standalone page make serve serves,
in headless Chrome), the TypeScript implementation (book/examples/tictactoe.ts) played as a web page,
and the Referee's log checked by session_conform against the protocol. Writes data/*.json and
data/*.png, and book/generated/walk-*.png for the book. Needs make serve. Usage: capture.py"""
import json, os, re, shutil, urllib.request
from playwright.sync_api import sync_playwright

D = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data"); BOOK = os.path.join(ROOT, "book", "generated")
os.makedirs(DATA, exist_ok=True)
FILE = "examples/sessions/TicTacToe.leanfm"
URL = "http://127.0.0.1:8080"


def mcp(tool, args):
    b = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}
    r = urllib.request.Request(URL + "/mcp", json.dumps(b).encode(), {"Content-Type": "application/json", "Accept": "application/json"})
    res = json.loads(urllib.request.urlopen(r, timeout=120).read())["result"]
    if res.get("isError"): raise SystemExit(f"{tool} refused: {res['content'][0]['text'][:300]}")
    return res.get("structuredContent") or {"text": res["content"][0]["text"]}, res["content"][0]["text"]


def strip_types(ts):
    """The TypeScript as JavaScript: the source is written so that its types are only `type` lines and
    annotations of these names, which this removes."""
    js = "\n".join(l for l in ts.splitlines() if not l.startswith("type "))
    js = re.sub(r"\??:\s*(Mark|Ev|number|string|void)(\[\])?(\s*\|\s*null)?(?=[\s,)={;])", "", js)
    return js


GLUE = """
const board = document.getElementById("board"), status = document.getElementById("status"), logView = document.getElementById("log");
function draw(msg) {
  board.replaceChildren(...cells.map((v, i) => { const b = document.createElement("button"); b.textContent = v || "";
    b.onclick = () => draw(moveX(i) || msg); return b; }));
  if (msg) status.textContent = msg;
  logView.textContent = events.map((e) => JSON.stringify(e)).join("\\n");
}
start(); draw("Your move, X");
"""

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>TicTacToe</title><style>
body{background:#0d1117;color:#e6edf3;font:18px system-ui,sans-serif;margin:24px;display:flex;gap:32px}
#board{display:grid;grid-template-columns:repeat(3,96px);gap:8px}
#board button{width:96px;height:96px;font-size:44px;font-weight:700;background:#161b22;color:#e6edf3;border:2px solid #30363d;border-radius:8px}
pre{font:14px ui-monospace,monospace;line-height:1.5;color:#a5d6ff;white-space:pre-wrap;margin:0}
h2{font-size:16px;color:#8b949e;font-weight:600;margin:0 0 8px}</style></head><body>
<div><h2>TicTacToe (you are X)</h2><div id="board"></div><p id="status"></p></div>
<div style="flex:1"><h2>The Referee's log: one event per protocol message</h2><pre id="log"></pre></div>
<script>%s
%s</script></body></html>"""


def main():
    ts = open(os.path.join(ROOT, "book", "examples", "tictactoe.ts")).read()
    page = os.path.join(D, "build", "game.html"); os.makedirs(os.path.dirname(page), exist_ok=True)
    open(page, "w").write(PAGE % (strip_types(ts), GLUE))
    intro, intro_text = mcp("introduction", {})
    explore, _ = mcp("session_explore", {"project": "LeanFM", "file": FILE})
    check, _ = mcp("session_check", {"project": "LeanFM", "file": FILE})
    shots = {}
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path="/usr/bin/google-chrome")
        # the game, played: X takes the centre and corners until the game ends
        g = b.new_page(viewport={"width": 1500, "height": 520}, color_scheme="dark")
        g.goto("file://" + page)
        for cell in [4, 0, 8, 2, 6, 1, 3, 5, 7]:
            if g.evaluate("over"): break
            if g.evaluate(f"cells[{cell}] === null"): g.locator("#board button").nth(cell).click()
        events = g.evaluate("events"); outcome = g.locator("#status").inner_text()
        g.screenshot(path=os.path.join(DATA, "game.png")); shots["game"] = "game.png"
        # the viewer, opened on the protocol file's requirements list
        v = b.new_page(viewport={"width": 1400, "height": 1000}, color_scheme="dark")
        v.goto(f"{URL}/view?project=LeanFM&file={FILE}")
        v.wait_for_timeout(14000)
        f0 = next(fr for fr in v.frames if fr.url.endswith("/view/app"))
        f0.locator(".panel").filter(has_text="TREE: CLICK A NAME").first.screenshot(path=os.path.join(DATA, "tree.png")); shots["tree"] = "tree.png"
        f = next(fr for fr in v.frames if fr.url.endswith("/view/app"))
        btn = lambda text: f.locator("button").filter(has_text=re.compile("^" + text + "$")).first
        btn("Whole protocol").click(); v.wait_for_timeout(5000)
        # open the loop's frame and the otherwise frame, which the view folds at first
        for frame_name in ["Round, at most 5", "otherwise, after 5"]:
            f.locator("rect.hot[aria-label='Show the interaction of group " + frame_name + "']").first.dispatch_event("click")
            v.wait_for_timeout(1500)
        panel = f.locator(".panel").filter(has_text="SEQUENCE DIAGRAM, GENERATED FROM THE PROTOCOL").first
        panel.screenshot(path=os.path.join(DATA, "diagram.png")); shots["diagram"] = "diagram.png"
        btn("Behaviour").click(); v.wait_for_timeout(1500)
        f.locator("button").filter(has_text=re.compile("^Animate")).first.click(); v.wait_for_timeout(7000)
        stream = f.locator(".panel").filter(has_text="EVENT STREAM").first
        stream.screenshot(path=os.path.join(DATA, "animate.png")); shots["animate"] = "animate.png"
        b.close()
    conform, _ = mcp("session_conform", {"project": "LeanFM", "file": FILE, "events": events})
    json.dump({"intro": intro, "introText": intro_text, "explore": {"reading": explore.get("reading")}, "check": {"verdict": check.get("verdict"), "reading": check.get("reading")},
               "events": events, "outcome": outcome, "conform": {k: conform.get(k) for k in ("verdict", "reading")},
               "shots": shots, "typescript": ts}, open(os.path.join(DATA, "walk.json"), "w"), indent=1)
    for k, name in shots.items(): shutil.copy(os.path.join(DATA, name), os.path.join(BOOK, f"walk-{k}.png"))
    # the checked run, as the book prints it: a tool's answer
    open(os.path.join(BOOK, "walk-conform.tex"), "w").write(
        "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\footnotesize,breaklines=true]\n"
        f"{outcome}: {len(events)} events from the Referee's log\n"
        f"session_conform: {conform.get('verdict')}: {conform.get('reading')}\n"
        "\\end{lstlisting}\n")
    print(f"game: {outcome}, {len(events)} events; conform: {conform.get('verdict')}: {conform.get('reading')}")


if __name__ == "__main__":
    main()
