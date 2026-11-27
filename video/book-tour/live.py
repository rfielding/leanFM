"""GoServer, watched live: start a fresh game between two server bots, open it in GoServer's own web app
as a watcher (headless Chrome), and every GAP seconds capture the board and ask LeanFM, over MCP, to
check the new lines of GoServer/events against the protocol Turn, from the previous answer's nextLine.
Needs GoServer (make run in projects/GoServer, port 8081) and make serve. Writes data/live.json and
data/live-<k>.png. Usage: live.py [shots] [gap]"""
import json, os, random, sys, time, urllib.request, urllib.error
from playwright.sync_api import sync_playwright
D = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(os.path.dirname(D))
DATA = os.path.join(D, "data"); LOG = os.path.join(ROOT, "projects/GoServer/logs/events.log")
SHOTS = int(sys.argv[1]) if len(sys.argv) > 1 else 4
GAP = float(sys.argv[2]) if len(sys.argv) > 2 else 40

def post(path, body):
    r = urllib.request.Request("http://127.0.0.1:8081" + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    try: return json.loads(urllib.request.urlopen(r, timeout=60).read())
    except urllib.error.HTTPError as e: sys.exit(f"{path}: {e.code} {e.read().decode()[:300]}")
def mcp(tool, args):
    b = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}
    r = urllib.request.Request("http://127.0.0.1:8080/mcp", json.dumps(b).encode(), {"Content-Type": "application/json", "Accept": "application/json"})
    res = json.loads(urllib.request.urlopen(r, timeout=120).read())["result"]
    if res.get("isError"): sys.exit(f"{tool} refused: {res['content'][0]['text'][:300]}")
    return res.get("structuredContent") or res["content"][0]["text"]

listing = mcp("server_logs", {})
listing = [l for l in (listing if isinstance(listing, str) else json.dumps(listing)).splitlines() if "/events" in l]
start = sum(1 for _ in open(LOG)) + 1 if os.path.exists(LOG) else 1
name = f"tour game {random.randint(100, 999)}"
sid = post("/api/issue_session", {"identity": f"host{random.randint(1000, 9999)}"})["session"]
post("/api/enter_room", {"sessionId": sid, "roomId": "lobby", "requestId": 10})
g = post("/api/create_game", {"sessionId": sid, "roomId": "lobby", "gameName": name, "boardSize": 9, "seats": 2, "mainTimeMs": 0,
         "byoyomiPeriods": 0, "byoyomiMs": 0, "koRule": 0, "exploreMilli": 1400, "rewardMode": "", "softness": 0,
         "seatPlan": [{"seat": 1, "controller": "bot", "team": 1}, {"seat": 2, "controller": "bot", "team": 2}], "requestId": 11})
post("/api/start_game", {"sessionId": sid, "gameId": g["gameId"], "requestId": 12})
steps, cursor = [], start
with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/usr/bin/google-chrome")
    pg = b.new_page(viewport={"width": 1500, "height": 1400}, color_scheme="dark")
    pg.goto("http://127.0.0.1:8081/"); pg.wait_for_selector(".session-form")
    pg.fill(".identity", f"watcher{random.randint(1000, 9999)}")
    pg.eval_on_selector(".session-form", "f => f.requestSubmit()")
    pg.locator(".challenge-card", has_text=name).get_by_text("Open challenge").click()
    pg.wait_for_selector(".room-panel:not([hidden]) .game-panel:not([hidden]) canvas.board", timeout=20000)
    for k in range(SHOTS):
        pg.wait_for_timeout(int(GAP * 1000))
        png = os.path.join(DATA, f"live-{k}.png")
        pg.screenshot(path=png, clip={"x": 16, "y": 320, "width": 1468, "height": 1060})
        a = mcp("session_conform", {"project": "GoServer", "file": "spec/GoServer.leanfm", "protocolName": "Turn",
                                    "serverLog": "GoServer/events", "fromLine": cursor, "allowIncomplete": True})
        lines = open(LOG).read().splitlines()
        steps.append({"at": round((k + 1) * GAP), "fromLine": cursor, "nextLine": a["nextLine"], "verdict": a["verdict"],
                      "reading": a["reading"], "newest": [l[:170] for l in lines[-2:]]})
        print(steps[-1]["at"], a["verdict"], a["reading"])
        cursor = a["nextLine"]
    b.close()
json.dump({"listing": listing, "game": {"id": g["gameId"], "name": name}, "startLine": start, "steps": steps},
          open(os.path.join(DATA, "live.json"), "w"), indent=1)
