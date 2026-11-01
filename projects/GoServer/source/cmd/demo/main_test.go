package main

// Requirement refs: goserver authorized correlated results, no foreign scope;
// spec/runtime.json independent loopback launch; local HTTP request boundary.
import (
	"bytes"
	"encoding/json"
	"github.com/leanfm/goserver"
	"net/http"
	"net/http/httptest"
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
	for _, path := range []string{"/", "/app.js", "/style.css"} {
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
	game := call(t, h, "/api/create_game", map[string]any{"sessionId": token, "roomId": "lobby", "gameName": "duel", "boardSize": 9, "seats": 2, "turnDeadlineMs": 60000, "koRule": 2, "botMs": 250, "requestId": 2})
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
	for _, path := range []string{"/engine.js", "/search-worker.js", "/gameview.js"} {
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
