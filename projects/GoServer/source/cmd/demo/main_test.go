package main

// Requirement refs: goserver authorized correlated results, no foreign scope;
// spec/runtime.json independent loopback launch; local HTTP request boundary.
import (
	"bytes"
	"encoding/json"
	"github.com/leanfm/goserver"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func call(t *testing.T, h http.Handler, path string, body any) map[string]any {
	t.Helper()
	b, _ := json.Marshal(body)
	r := httptest.NewRequest("POST", "http://127.0.0.1:8081"+path, bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("%s returned %d: %s", path, w.Code, w.Body.String())
	}
	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}
func TestBrowserWireFieldsActuallyReachTheCore(t *testing.T) {
	h := newHandler(goserver.NewServer(), "8081")
	token := call(t, h, "/api/issue_session", map[string]any{"identity": "alice"})["session"].(string)
	rooms := call(t, h, "/api/list_rooms", map[string]any{"sessionId": token, "requestId": 1})
	if rooms["requestId"] != float64(1) || rooms["roomIds"].([]any)[0] != "lobby" {
		t.Fatal(rooms)
	}
	call(t, h, "/api/enter_room", map[string]any{"sessionId": token, "roomId": "lobby", "requestId": 2})
	game := call(t, h, "/api/create_game", map[string]any{"sessionId": token, "roomId": "lobby", "gameName": "friendly", "requestId": 3})
	gameID, ok := game["gameId"].(string)
	if !ok || game["creator"] != "alice" {
		t.Fatal(game)
	}
	call(t, h, "/api/join_game", map[string]any{"sessionId": token, "gameId": gameID, "requestId": 4})
	chat := call(t, h, "/api/send_game_chat", map[string]any{"sessionId": token, "gameId": gameID, "body": "hello", "requestId": 5})
	if chat["sender"] != "alice" || chat["body"] != "hello" || chat["gameId"] != gameID {
		t.Fatal(chat)
	}
	bad := call(t, h, "/api/list_rooms", map[string]any{"sessionId": "sess-1", "requestId": 6})
	if bad["code"] != "unauthorized" {
		t.Fatal(bad)
	}
}
func TestMethodOriginHostAndBodyRejections(t *testing.T) {
	h := newHandler(goserver.NewServer(), "8081")
	cases := []struct {
		method, body, host, origin string
		status                     int
	}{
		{"GET", "", "127.0.0.1:8081", "", 405},
		{"POST", `{"identity":"alice","unknown":true}`, "127.0.0.1:8081", "", 400},
		{"POST", `{"identity":"alice"} {}`, "127.0.0.1:8081", "", 400},
		{"POST", `{"identity":"alice"}`, "attacker.invalid:8081", "", 403},
		{"POST", `{"identity":"alice"}`, "127.0.0.1:8081", "https://attacker.invalid", 403},
		{"POST", strings.Repeat("x", 40000), "127.0.0.1:8081", "", 400},
	}
	for _, c := range cases {
		r := httptest.NewRequest(c.method, "http://127.0.0.1:8081/api/issue_session", strings.NewReader(c.body))
		r.Host = c.host
		r.Header.Set("Origin", c.origin)
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != c.status {
			t.Fatalf("%+v: %d %s", c, w.Code, w.Body.String())
		}
	}
}
func TestDefaultPortCannotCollideWithLeanFM(t *testing.T) {
	t.Setenv("LEANFM_PORT", "8080")
	t.Setenv("GOSERVER_PORT", "")
	if port, err := portFromEnv(); err != nil || port != "8081" {
		t.Fatalf("%q %v", port, err)
	}
	for _, bad := range []string{"8080", "08080", "+8080", "-1", "65536", "wrong"} {
		t.Setenv("GOSERVER_PORT", bad)
		if _, err := portFromEnv(); err == nil {
			t.Fatal("accepted unsafe port", bad)
		}
	}
	t.Setenv("GOSERVER_PORT", "8090")
	if port, err := portFromEnv(); err != nil || port != "8090" {
		t.Fatal(port, err)
	}
}

// Requirement refs: grammar:create_room; browser working controls; scope isolation.
func TestBrowserCreatesRoomsAndReadsOnlyAuthorizedHistory(t *testing.T) {
	s := goserver.NewServer()
	h := newHandler(s, "8081")
	alice := call(t, h, "/api/issue_session", map[string]any{"identity": "alice"})["session"].(string)
	bob := call(t, h, "/api/issue_session", map[string]any{"identity": "bob"})["session"].(string)
	created := call(t, h, "/api/create_room", map[string]any{"sessionId": alice, "roomName": "Study room", "requestId": 1})
	room := created["roomId"].(string)
	call(t, h, "/api/enter_room", map[string]any{"sessionId": alice, "roomId": room, "requestId": 2})
	game := call(t, h, "/api/create_game", map[string]any{"sessionId": alice, "roomId": room, "gameName": "Evening game", "requestId": 3})
	if game["gameName"] != "Evening game" {
		t.Fatal(game)
	}
	call(t, h, "/api/send_room_chat", map[string]any{"sessionId": alice, "roomId": room, "body": "room only", "requestId": 4})
	history := call(t, h, "/api/room_history", map[string]any{"sessionId": alice, "roomId": room})
	if history["items"].([]any)[0].(map[string]any)["body"] != "room only" {
		t.Fatal(history)
	}
	body, _ := json.Marshal(map[string]any{"sessionId": bob, "roomId": room})
	request := httptest.NewRequest("POST", "http://127.0.0.1:8081/api/room_history", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	if recorder.Code != 403 || strings.Contains(recorder.Body.String(), "room only") {
		t.Fatal(recorder.Body.String())
	}
}
func TestPageAssetsAndUnsupportedDestinations(t *testing.T) {
	h := newHandler(goserver.NewServer(), "8081")
	for _, path := range []string{"/", "/app/app.js", "/app/app.css"} {
		request := httptest.NewRequest("GET", "http://127.0.0.1:8081"+path, nil)
		recorder := httptest.NewRecorder()
		h.ServeHTTP(recorder, request)
		if recorder.Code != 200 || recorder.Body.Len() == 0 {
			t.Fatal(path, recorder.Code)
		}
		if strings.Contains(recorder.Header().Get("Content-Security-Policy"), "unsafe-inline") {
			t.Fatal("inline execution allowed")
		}
	}
	request := httptest.NewRequest("GET", "http://127.0.0.1:8081/fake-game", nil)
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	if recorder.Code != 404 {
		t.Fatal("fabricated destination accepted")
	}
}

// Requirement refs: grammar:take_seat, grammar:start_game, grammar:play_move, grammar:game_state.
func TestGameplayWireFieldsReachTheCore(t *testing.T) {
	core := goserver.NewServer()
	defer core.Close()
	h := newHandler(core, "8081")
	token := call(t, h, "/api/issue_session", map[string]any{"identity": "alice"})["session"].(string)
	call(t, h, "/api/enter_room", map[string]any{"sessionId": token, "roomId": "lobby", "requestId": 1})
	game := call(t, h, "/api/create_game", map[string]any{"sessionId": token, "roomId": "lobby", "gameName": "duel", "boardSize": 9, "seats": 2, "mainTimeMs": 60000, "byoyomiPeriods": 1, "byoyomiMs": 10000, "koRule": 2, "requestId": 2})
	id := game["gameId"].(string)
	if game["boardSize"] != float64(9) || game["seats"] != float64(2) || game["koRule"] != float64(2) {
		t.Fatal(game)
	}
	call(t, h, "/api/join_game", map[string]any{"sessionId": token, "gameId": id, "requestId": 3})
	seat := call(t, h, "/api/take_seat", map[string]any{"sessionId": token, "gameId": id, "seat": 1, "requestId": 4})
	if seat["seat"] != float64(1) {
		t.Fatal(seat)
	}
	started := call(t, h, "/api/start_game", map[string]any{"sessionId": token, "gameId": id, "requestId": 5})
	seats := started["seats"].([]any)
	if seats[1].(map[string]any)["controller"] != "bot" {
		t.Fatal(started)
	}
	played := call(t, h, "/api/play_move", map[string]any{"sessionId": token, "gameId": id, "moveNo": 0, "kind": "place", "x": 4, "y": 4, "requestId": 6})
	if played["seat"] != float64(1) || played["x"] != float64(4) {
		t.Fatal(played)
	}
	state := call(t, h, "/api/game_state", map[string]any{"sessionId": token, "gameId": id, "requestId": 7})
	if state["status"] != "playing" || len(state["cells"].([]any)) != 81 || state["cells"].([]any)[40] != float64(1) {
		t.Fatal(state)
	}
}

// Requirement refs: property:Lab-style viewer; property:Analysis is local; grammar:set_seat_plan, grammar:set_autopilot, grammar:propose_merge.
func TestLabAssetsAndNewRoutes(t *testing.T) {
	core := goserver.NewServer()
	defer core.Close()
	h := newHandler(core, "8081")
	for _, path := range []string{"/engine.js", "/search-worker.js", "/app/app.js"} {
		r := httptest.NewRequest("GET", "http://127.0.0.1:8081"+path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 200 || !strings.Contains(w.Header().Get("Content-Type"), "javascript") || !strings.Contains(w.Header().Get("Content-Security-Policy"), "worker-src 'self'") {
			t.Fatalf("%s: %d %v", path, w.Code, w.Header())
		}
	}
	token := call(t, h, "/api/issue_session", map[string]any{"identity": "alice"})["session"].(string)
	call(t, h, "/api/enter_room", map[string]any{"sessionId": token, "roomId": "lobby", "requestId": 1})
	game := call(t, h, "/api/create_game", map[string]any{"sessionId": token, "roomId": "lobby", "gameName": "g", "seats": 2, "boardSize": 5, "exploreMilli": 1000, "rewardMode": "win", "softness": 2, "seatPlan": []map[string]any{{"seat": 2, "controller": "bot", "team": 1}}, "requestId": 2})
	id := game["gameId"].(string)
	if game["rewardMode"] != "win" || len(game["seatPlan"].([]any)) != 2 {
		t.Fatal(game)
	}
	call(t, h, "/api/join_game", map[string]any{"sessionId": token, "gameId": id, "requestId": 3})
	if got := call(t, h, "/api/set_seat_plan", map[string]any{"sessionId": token, "gameId": id, "seat": 2, "controller": "bot", "team": 2, "requestId": 4}); got["team"] != float64(2) {
		t.Fatal(got)
	}
	call(t, h, "/api/take_seat", map[string]any{"sessionId": token, "gameId": id, "seat": 1, "requestId": 5})
	call(t, h, "/api/start_game", map[string]any{"sessionId": token, "gameId": id, "requestId": 6})
	if got := call(t, h, "/api/set_autopilot", map[string]any{"sessionId": token, "gameId": id, "on": true, "requestId": 7}); got["on"] != true {
		t.Fatal(got)
	}
	if got := call(t, h, "/api/propose_merge", map[string]any{"sessionId": token, "gameId": id, "otherTeam": 2, "requestId": 8}); got["code"] != "no_person_on_team" {
		t.Fatal(got)
	}
	if got := call(t, h, "/api/respond_merge", map[string]any{"sessionId": token, "gameId": id, "proposalId": 9, "accept": true, "requestId": 9}); got["code"] != "no_proposal" {
		t.Fatal(got)
	}
	if got := call(t, h, "/api/leave_seat", map[string]any{"sessionId": token, "gameId": id, "requestId": 10}); got["code"] != "not_open" {
		t.Fatal(got)
	}
}

// webSource reads the React app's TypeScript source (web/src), which the served bundle is built from.
func webSource(t *testing.T, name string) string {
	b, err := os.ReadFile(filepath.Join("..", "..", "web", "src", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// The page is the React app: one tab per open room, and inside a room a Lobby tab plus one tab
// per open game; the game view keeps a play bar outside its side tabs; the pointer preview is
// gated by the same rules as a click and never talks to the server. book_tour.py and
// browser_check.py check the behaviour in Chrome.
func TestRoomAndGameTabsAndPointerPreview(t *testing.T) {
	core := goserver.NewServer()
	defer core.Close()
	h := newHandler(core, "8081")
	r := httptest.NewRequest("GET", "http://127.0.0.1:8081/", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	page := w.Body.String()
	if !strings.Contains(page, `<div id="root"></div>`) || !strings.Contains(page, `src="./app/app.js"`) || strings.Index(page, `src="./engine.js"`) > strings.Index(page, `src="./app/app.js"`) {
		t.Fatal("the page must load the rules engine, then the React app")
	}
	app, room, game, panels, ctl := webSource(t, "ui/App.tsx"), webSource(t, "ui/Room.tsx"), webSource(t, "ui/Game.tsx"), webSource(t, "ui/Panels.tsx"), webSource(t, "game/game.ts")
	if !strings.Contains(app, `label="Rooms" className="room-tabs"`) || !strings.Contains(room, `className="game-tabs"`) || !strings.Contains(room, "id: LOBBY, label: 'Lobby'") {
		t.Fatal("room tabs and per-room game tabs are missing")
	}
	// responses are applied only to the room or game that asked
	for _, guard := range []string{"r.roomId === roomId", "r.gameId !== gameId"} {
		if !strings.Contains(room+game, guard) {
			t.Fatalf("missing scope guard %q", guard)
		}
	}
	if !strings.Contains(ctl, "st.gameId !== this.gameId") {
		t.Fatal("game state is not scoped to its own game")
	}
	bar := panels[strings.Index(panels, "export function PlayBar"):strings.Index(panels, "function Timeline")]
	for _, part := range []string{"<Status", "gv-pass", "gv-resign", "gv-autopilot", "clock"} {
		if !strings.Contains(bar, part) {
			t.Fatalf("%s is not in the always-visible play bar", part)
		}
	}
	if !strings.Contains(game, `className="side-tabs"`) {
		t.Fatal("game side panels are not tabbed")
	}
	gate := ctl[strings.Index(ctl, "canPlaceAt(node: any, m: number)"):strings.Index(ctl, "setHover(")]
	for _, rule := range []string{"cells[m] !== 0", "isTerminal(", "myLiveTurn()", "analysisAllowed()", "isLegal("} {
		if !strings.Contains(gate, rule) {
			t.Fatalf("pointer preview gate lacks %q", rule)
		}
	}
	board := webSource(t, "ui/Board.tsx")
	move := board[strings.Index(board, "onPointerMove"):]
	move = move[:strings.Index(move, "\n")]
	if strings.Contains(move, "api(") || strings.Contains(move, "fetch(") {
		t.Fatal("the pointer preview must not talk to the server")
	}
}

// After a restart the server forgets sessions; the page must fall back to the name form rather
// than strand the person. Text stays light on dark so dark-mode extensions cannot make it
// unreadable, and player colours are drawn on canvases, which those extensions leave alone.
func TestSessionRecoveryAndLightOnDark(t *testing.T) {
	core := goserver.NewServer()
	defer core.Close()
	h := newHandler(core, "8081")
	if got := call(t, h, "/api/list_rooms", map[string]any{"sessionId": "forgotten-by-a-restart", "requestId": 1}); got["code"] != "unauthorized" {
		t.Fatalf("a stale session must be rejected as unauthorized, got %v", got)
	}
	api, css, common := webSource(t, "api.ts"), webSource(t, "styles.css"), webSource(t, "ui/common.tsx")
	if !strings.Contains(api, "result.code === 'unauthorized' && auth.session) sessionLost()") || !strings.Contains(api, "goserver:lastName") {
		t.Fatal("the app does not recover from a forgotten session")
	}
	if strings.Contains(css, "color:var(--accent-ink)") {
		t.Fatal("dark text on the accent fill is unreadable under dark-mode extensions")
	}
	if !strings.Contains(common, "drawSwatch(") || !strings.Contains(common, "<canvas") {
		t.Fatal("player colours must be drawn on a canvas")
	}
	r := httptest.NewRequest("GET", "http://127.0.0.1:8081/", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if !strings.Contains(w.Body.String(), `name="darkreader-lock"`) {
		t.Fatal("page does not opt out of Dark Reader")
	}
}

func status(h http.Handler, path string, body any) (int, string) {
	b, _ := json.Marshal(body)
	r := httptest.NewRequest("POST", "http://127.0.0.1:8081"+path, bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w.Code, w.Body.String()
}

// Requirement refs: property:sign_in honours claims; proof:sign_in never lets anyone
// borrow a claimed name; property:ranking is computed from rated games.
func TestClaimSignInAndRankingOverHTTP(t *testing.T) {
	accounts, err := goserver.OpenAccounts(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	h := newHandler(goserver.NewServerWith(accounts), "8081")
	claimed := call(t, h, "/api/claim_name", map[string]any{"identity": "grace", "password": "a good password", "requestId": 1})
	token, _ := claimed["session"].(string)
	if claimed["identity"] != "grace" || token == "" {
		t.Fatal(claimed)
	}
	if code, body := status(h, "/api/issue_session", map[string]any{"identity": "Grace"}); code != 401 || strings.Contains(body, "pbkdf2") {
		t.Fatalf("claimed name without a password: %d %s", code, body)
	}
	for i := 0; i < 5; i++ {
		if code, _ := status(h, "/api/issue_session", map[string]any{"identity": "grace", "password": "not it"}); code != 401 {
			t.Fatalf("wrong password %d: %d", i, code)
		}
	}
	if code, _ := status(h, "/api/issue_session", map[string]any{"identity": "grace", "password": "a good password"}); code != 429 {
		t.Fatalf("throttled attempt: %d", code)
	}
	ranking := call(t, h, "/api/ranking", map[string]any{"sessionId": token, "requestId": 2})
	if ranking["ratedGames"] != float64(0) {
		t.Fatal(ranking)
	}
	if code, _ := status(h, "/api/issue_session", map[string]any{"identity": "bot-3"}); code != 400 {
		t.Fatal("a person took a bot name")
	}
	signed := call(t, h, "/api/sign_out", map[string]any{"sessionId": token, "requestId": 3})
	if signed["requestId"] != float64(3) {
		t.Fatal(signed)
	}
}

// Requirement refs: property:change_password needs the current password; property:release_name frees the name.
func TestChangePasswordAndReleaseOverHTTP(t *testing.T) {
	h := newHandler(goserver.NewServer(), "8081")
	call(t, h, "/api/claim_name", map[string]any{"identity": "ken", "password": "ken's first", "requestId": 1})
	changed := call(t, h, "/api/change_password", map[string]any{"identity": "ken", "password": "ken's first", "newPassword": "ken's second", "requestId": 2})
	if changed["identity"] != "ken" || changed["session"] == "" {
		t.Fatal(changed)
	}
	bad := call(t, h, "/api/release_name", map[string]any{"identity": "ken", "password": "ken's first", "requestId": 3})
	if bad["code"] != "wrong_password" {
		t.Fatal(bad)
	}
	if got := call(t, h, "/api/release_name", map[string]any{"identity": "ken", "password": "ken's second", "requestId": 4}); got["identity"] != "ken" {
		t.Fatal(got)
	}
	if code, _ := status(h, "/api/issue_session", map[string]any{"identity": "ken"}); code != 200 {
		t.Fatal("released name not free")
	}
}

// Requirement refs: property:session type panel; proof:the session type panel never misleads.
// The panel's text must be the current session types of spec/Session.lean; rerun
// `lake env lean --run projects/GoServer/spec/SessionPanel.lean` from the LeanFM root.
func TestSessionPanelMatchesTheSpec(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "..", "..", "spec", "Session.lean"))
	if err != nil {
		t.Fatal(err)
	}
	var kept []string
	inside := false
	for _, line := range strings.Split(string(src), "\n") {
		switch {
		case strings.HasPrefix(line, "--@begin "):
			inside = true
		case strings.HasPrefix(line, "--@end "):
			inside = false
		case inside:
			kept = append(kept, line)
		}
	}
	// the panel's text is a Lean file of its own: the import header, then the regions verbatim
	if want := "import LeanFM.Session.Syntax\n\n" + strings.Join(kept, "\n") + "\n"; sessionText != want {
		t.Fatal("static/session/goserver.leanfm is stale: regenerate it with spec/SessionPanel.lean")
	}
	h := newHandler(goserver.NewServer(), "8081")
	impl, err := os.ReadFile("../../../spec/Implementation.lean")
	if err != nil {
		t.Fatal(err)
	}
	if sessionImplementation != string(impl) {
		t.Fatal("static/session/implementation.lean is stale: regenerate it with spec/SessionPanel.lean")
	}
	if !strings.HasPrefix(sessionBook, "%PDF-") {
		t.Fatal("static/session/goserver-dark.pdf is not a PDF")
	}
	if book, err := os.ReadFile("../../../book/main-dark.pdf"); err == nil && string(book) != sessionBook {
		t.Fatal("static/session/goserver-dark.pdf is stale: regenerate it with spec/SessionPanel.lean")
	}
	for path, kind := range map[string]string{"/session/goserver.svg": "image/svg+xml", "/session/goserver.leanfm": "text/plain", "/session/provenance.json": "application/json",
		"/session/implementation.lean": "text/plain", "/session/goserver-dark.pdf": "application/pdf"} {
		r := httptest.NewRequest("GET", "http://127.0.0.1:8081"+path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 200 || !strings.HasPrefix(w.Header().Get("Content-Type"), kind) {
			t.Fatalf("%s: %d %s", path, w.Code, w.Header().Get("Content-Type"))
		}
	}
	if !strings.Contains(sessionSVG, "ClockRanOut") || !strings.Contains(sessionSVG, "PlayMove") || strings.Contains(sessionSVG, "<script") {
		t.Fatal("the session diagram is not the current GoServer protocol, or carries script")
	}
	var prov map[string]any
	if json.Unmarshal([]byte(sessionProvenance), &prov) != nil || prov["protocol"] != "GoServer" || prov["reducer"] == nil || prov["boundary"] == nil {
		t.Fatalf("provenance: %s", sessionProvenance)
	}
}

// Every route the session type declares (route "POST /api/..." in spec/Session.lean, carried into
// the generated static/session/goserver.leanfm) is served by this handler with POST, and refused
// with 405 for any other method: the spec and the server agree on the HTTP interface.
// The session type names the person's session in every log: sign-in mints sessionId, every
// request carries it as a Link, and each request protocol run beside the game is given it, so
// LeanFM separates a log without session ids into one session per person.
func TestSessionTypeNamesThePersonsSession(t *testing.T) {
	raw, err := os.ReadFile("static/session/goserver.leanfm")
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if !regexp.MustCompile(`structure SessionIssued where\n(?:  .*\n)*?  sessionId : Fresh String`).MatchString(text) {
		t.Fatal("SessionIssued must mint sessionId (Fresh String)")
	}
	// negative: no message carries an unmarked sessionId, so none is placed by guesswork
	if regexp.MustCompile(`(?m)^  sessionId : String$`).MatchString(text) {
		t.Fatal("a message carries sessionId unmarked; every request must carry it as Link String")
	}
	for _, m := range []string{"EnterRoom", "CreateGame", "PlayMove", "SetAutopilot", "GetGameState", "ProposeMerge", "RespondMerge"} {
		if !regexp.MustCompile(`structure ` + m + ` where\n(?:  .*\n)*?  sessionId : Link String`).MatchString(text) {
			t.Fatalf("%s must carry sessionId as Link String", m)
		}
	}
	for _, p := range []string{"CreateRoomP", "ListGamesP", "RoomChatP"} {
		if !strings.Contains(text, "include "+p+" Person Server with sessionId;") {
			t.Fatalf("%s must be included with sessionId", p)
		}
	}
	if !strings.Contains(text, "sessions { include GameP Person Server Bot with sessionId; }") {
		t.Fatal("a game must run in a sessions block, given the creator's sessionId")
	}
}

// A game is a session its players join: GameCreated mints gameId, the game's session holds its
// challenge and turns, and every seat and game request is given both sessionId and gameId.
func TestSessionTypeRunsGamesAsSessions(t *testing.T) {
	raw, err := os.ReadFile("static/session/goserver.leanfm")
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if !regexp.MustCompile(`structure GameCreated where\n(?:  .*\n)*?  gameId : Fresh String`).MatchString(text) {
		t.Fatal("GameCreated must mint gameId (Fresh String)")
	}
	// a picked game is only a reference: JoinGame and GameJoined carry gameId unmarked
	for _, m := range []string{"JoinGame", "GameJoined"} {
		if !regexp.MustCompile(`structure ` + m + ` where\n(?:  .*\n)*?  gameId : String\n`).MatchString(text) {
			t.Fatalf("%s must carry gameId as a plain reference", m)
		}
	}
	// negative: the turns carry only the game's id, so they never land in a person's session
	for _, m := range []string{"BotTurn", "BotMoveChosen"} {
		if regexp.MustCompile(`structure ` + m + ` where\n(?:  .*\n)*?  sessionId :`).MatchString(text) {
			t.Fatalf("%s must not carry a person's sessionId", m)
		}
	}
	for _, p := range []string{"TakeSeatP", "PlayMoveP", "SetAutopilotP", "ProposeMergeP", "RespondMergeP", "GameStateP", "SeatP"} {
		if !strings.Contains(text, "protocol "+p+" (Person, Server) given sessionId gameId {") {
			t.Fatalf("%s must be given sessionId and gameId", p)
		}
		if !strings.Contains(text, "include "+p+" Person Server with sessionId, gameId;") {
			t.Fatalf("%s must be included with sessionId, gameId", p)
		}
	}
}

func TestSessionTypeRoutesAreServedOnlyWithPost(t *testing.T) {
	text, err := os.ReadFile("static/session/goserver.leanfm")
	if err != nil {
		t.Fatal(err)
	}
	routes := regexp.MustCompile(`route "POST (/api/[a-z_]+)"`).FindAllStringSubmatch(string(text), -1)
	if len(routes) < 14 {
		t.Fatalf("expected the session type's 14 routed requests, found %d", len(routes))
	}
	h := newHandler(goserver.NewServer(), "8081")
	for _, m := range routes {
		path := m[1]
		for _, method := range []string{"GET", "PUT", "DELETE", "PATCH"} {
			r := httptest.NewRequest(method, "http://127.0.0.1:8081"+path, strings.NewReader(`{}`))
			r.Host = "127.0.0.1:8081"
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != 405 || w.Header().Get("Allow") != "POST" {
				t.Fatalf("%s %s: got %d (Allow %q), want 405 with Allow: POST", method, path, w.Code, w.Header().Get("Allow"))
			}
		}
		r := httptest.NewRequest("POST", "http://127.0.0.1:8081"+path, strings.NewReader(`{}`))
		r.Host = "127.0.0.1:8081"
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code == 404 || w.Code == 405 {
			t.Fatalf("POST %s: got %d; the session type routes it, so the server must serve it", path, w.Code)
		}
	}
}

// Requirement refs: property:API discovery. /openapi.yaml is the generated OpenAPI document of
// exactly the routes the session type declares, and /.well-known/api-catalog (RFC 9727) points at
// it; both are read-only, and the catalog's links name only this host.
func TestOpenAPIAndAPICatalog(t *testing.T) {
	h := newHandler(goserver.NewServer(), "8081")
	get := func(method, path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:8081"+path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	w := get("GET", "/openapi.yaml")
	if w.Code != 200 || !strings.HasPrefix(w.Header().Get("Content-Type"), "application/yaml") {
		t.Fatalf("/openapi.yaml: %d %s", w.Code, w.Header().Get("Content-Type"))
	}
	doc := w.Body.String()
	if !strings.HasPrefix(doc, "# Generated by LeanFM") || !strings.Contains(doc, "\nopenapi: \"3.1.0\"\n") {
		t.Fatal("/openapi.yaml is not LeanFM's generated OpenAPI 3.1 YAML: regenerate it with spec/SessionPanel.lean")
	}
	// the document's paths are the session type's routes, no more and no fewer
	text, err := os.ReadFile("static/session/goserver.leanfm")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{}
	for _, m := range regexp.MustCompile(`route "POST (/api/[a-z_]+)"`).FindAllStringSubmatch(string(text), -1) {
		want[m[1]] = true
	}
	got := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?m)^  "(/api/[a-z_]+)":$`).FindAllStringSubmatch(doc, -1) {
		got[m[1]] = true
	}
	if len(want) == 0 || len(got) != len(want) {
		t.Fatalf("openapi.yaml has %d paths, the session type routes %d: regenerate it with spec/SessionPanel.lean", len(got), len(want))
	}
	for p := range want {
		if !got[p] {
			t.Fatalf("openapi.yaml lacks %s, which the session type routes: regenerate it with spec/SessionPanel.lean", p)
		}
	}
	// the catalog: a linkset whose one entry is anchored at /api/ and described by /openapi.yaml
	w = get("GET", "/.well-known/api-catalog")
	if w.Code != 200 || !strings.HasPrefix(w.Header().Get("Content-Type"), "application/linkset+json") ||
		!strings.Contains(w.Header().Get("Content-Type"), "rfc9727") {
		t.Fatalf("/.well-known/api-catalog: %d %s", w.Code, w.Header().Get("Content-Type"))
	}
	var catalog struct {
		Linkset []map[string]any `json:"linkset"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &catalog); err != nil || len(catalog.Linkset) != 1 {
		t.Fatalf("catalog: %v %s", err, w.Body.String())
	}
	entry := catalog.Linkset[0]
	desc, _ := entry["service-desc"].([]any)
	first, _ := func() (map[string]any, bool) {
		if len(desc) == 0 {
			return nil, false
		}
		m, ok := desc[0].(map[string]any)
		return m, ok
	}()
	if entry["anchor"] != "http://127.0.0.1:8081/api/" || first == nil || first["href"] != "http://127.0.0.1:8081/openapi.yaml" || first["type"] != "application/yaml" {
		t.Fatalf("catalog entry: %v", entry)
	}
	for _, link := range []string{"service-desc", "service-doc"} {
		for _, l := range entry[link].([]any) {
			href := l.(map[string]any)["href"].(string)
			if !strings.HasPrefix(href, "http://127.0.0.1:8081/") {
				t.Fatalf("%s points off this host: %s", link, href)
			}
			if got := get("GET", strings.TrimPrefix(href, "http://127.0.0.1:8081")); got.Code != 200 {
				t.Fatalf("%s %s: %d", link, href, got.Code)
			}
		}
	}
	// HEAD answers the Link header with no body (RFC 9727 section 2)
	w = get("HEAD", "/.well-known/api-catalog")
	if w.Code != 200 || w.Body.Len() != 0 || !strings.Contains(w.Header().Get("Link"), `rel="api-catalog"`) {
		t.Fatalf("HEAD catalog: %d %q %q", w.Code, w.Header().Get("Link"), w.Body.String())
	}
	// negative: both are read-only, and an unapproved Host gets nothing
	for _, path := range []string{"/openapi.yaml", "/.well-known/api-catalog"} {
		if w := get("POST", path); w.Code != 405 || !strings.Contains(w.Header().Get("Allow"), "GET") {
			t.Fatalf("POST %s: %d, want 405 with Allow: GET", path, w.Code)
		}
		r := httptest.NewRequest("GET", "http://evil.example:8081"+path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 403 || strings.Contains(w.Body.String(), "evil.example") {
			t.Fatalf("GET %s with a foreign Host: %d %s", path, w.Code, w.Body.String())
		}
	}
}
