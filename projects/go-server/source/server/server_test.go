package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image/gif"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"leanfm/goserver/game"
)

func testServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	s, e := New(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	h := httptest.NewServer(s.Handler())
	t.Cleanup(h.Close)
	return s, h
}
func call(t *testing.T, base, path, method, token string, body any) (int, Reply) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	r, e := http.NewRequest(method, base+path, reader)
	if e != nil {
		t.Fatal(e)
	}
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	response, e := (&http.Client{Timeout: 5 * time.Second}).Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer response.Body.Close()
	var reply Reply
	if e = json.NewDecoder(response.Body).Decode(&reply); e != nil {
		t.Fatal(e)
	}
	return response.StatusCode, reply
}
func room(t *testing.T, base string) (Reply, Reply) {
	t.Helper()
	status, a := call(t, base, "/api/games", "POST", "", map[string]any{"size": 5, "players": 2, "max_turns": 200, "name": "Alice"})
	if status != 201 {
		t.Fatal(status, a)
	}
	status, b := call(t, base, "/api/games/"+a.Game.ID+"/join", "POST", "", map[string]any{"name": "Bob"})
	if status != 200 {
		t.Fatal(status, b)
	}
	return a, b
}
func act(t *testing.T, base, id, token string, revision int, kind string, point int) (int, Reply) {
	return call(t, base, "/api/games/"+id+"/actions", "POST", token, map[string]any{"revision": revision, "action": game.Action{Kind: kind, Point: point}})
}

// R1/R3: two genuinely independent HTTP clients finish a server-authoritative game.
func TestTwoPlayersCompleteGameAndRestart(t *testing.T) {
	s, h := testServer(t)
	a, b := room(t, h.URL)
	id := a.Game.ID
	for i, step := range []struct {
		token, kind string
		point       int
	}{{a.Token, "move", 0}, {b.Token, "move", 1}, {a.Token, "move", 2}, {b.Token, "move", 3}, {a.Token, "pass", 0}, {b.Token, "pass", 0}} {
		status, reply := act(t, h.URL, id, step.token, i+1, step.kind, step.point)
		if status != 200 {
			t.Fatal(status, reply)
		}
		if len(reply.Events) != 3 || reply.Events[1].Message != "MoveEvent" || reply.Events[2].Message != "GameState" {
			t.Fatal("not a grammar-conforming turn", reply.Events)
		}
		if reply.Events[2].CauseID != reply.Events[0].ID || reply.Events[2].PriorIDs[0] != reply.Events[1].ID {
			t.Fatal("lost causal identity")
		}
	}
	_, final := call(t, h.URL, "/api/games/"+id+"/history", "GET", "", nil)
	if !final.Game.Position.Finished || len(final.Game.History) != 7 || final.Game.Position.Board[0] != 1 || final.Game.Position.Board[1] != 2 || final.Game.Position.Board[2] != 1 || final.Game.Position.Board[3] != 2 {
		t.Fatal(final)
	}
	restarted, e := New(s.root)
	if e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(restarted.rooms[id].Position, final.Game.Position) {
		t.Fatal("restart lost game")
	}
	raw, _ := os.ReadFile(filepath.Join(s.root, id+".json"))
	for _, token := range []string{a.Token, b.Token} {
		if bytes.Contains(raw, []byte(token)) {
			t.Fatal("raw token persisted")
		}
	}
}

// R1/R3/R6: a completed room is a state conflict for either seat, including
// after deadline Passes. Preserve a safe current snapshot, never seat verifiers.
func TestCompletedRoomReportsStateBeforeTurnAndDoesNotMutate(t *testing.T) {
	s, h := testServer(t)
	a, b := room(t, h.URL)
	s.mu.Lock()
	now := s.Now().Add(121 * time.Second)
	s.Now = func() time.Time { return now }
	s.mu.Unlock()
	_, final := call(t, h.URL, "/api/games/"+a.Game.ID, "GET", "", nil)
	if !final.Game.Position.Finished || len(final.Game.Actions) != 0 {
		t.Fatal("expected terminal public position without private history", final)
	}
	for _, token := range []string{a.Token, b.Token} {
		for _, revision := range []int{1, final.Game.Revision} {
			status, reply := act(t, h.URL, a.Game.ID, token, revision, "move", 4)
			if status != 409 || !strings.Contains(reply.Error, "game is complete") || reply.Game == nil || !reply.Game.Position.Finished {
				t.Fatal("completed game misreported as authorization failure", status, reply)
			}
			if len(reply.Game.Verifiers) != 0 || len(reply.Game.History) != 0 || reply.Game.Revision != final.Game.Revision || !reflect.DeepEqual(reply.Game.Position, final.Game.Position) {
				t.Fatal("rejection exposed credentials or changed the board", reply)
			}
			if len(reply.Events) != 2 || reply.Events[1].Message != "ErrorEvent" || reply.Events[1].CauseID != reply.Events[0].ID {
				t.Fatal("failure lost request correlation", reply.Events)
			}
		}
	}
}

func TestUnauthorizedStaleAndIllegalActionsDoNotMutate(t *testing.T) {
	_, h := testServer(t)
	a, b := room(t, h.URL)
	id := a.Game.ID
	for _, probe := range []struct {
		token                 string
		revision, point, want int
	}{{"", 1, 0, 401}, {strings.Repeat("a", 48), 1, 0, 401}, {b.Token, 1, 0, 403}, {a.Token, 0, 0, 409}, {a.Token, 1, 25, 422}} {
		status, reply := act(t, h.URL, id, probe.token, probe.revision, "move", probe.point)
		if status != probe.want || len(reply.Events) != 2 || reply.Events[1].Message != "ErrorEvent" {
			t.Fatal(status, reply)
		}
		if status == 403 || status == 409 {
			if reply.Game == nil || reply.Game.Revision != 1 || len(reply.Game.Verifiers) != 0 {
				t.Fatal("turn/revision rejection lost safe authoritative state", reply)
			}
		}
		_, current := call(t, h.URL, "/api/games/"+id, "GET", "", nil)
		if current.Game.Position.Ply != 0 || current.Game.Revision != 1 {
			t.Fatal("rejected action mutated game")
		}
	}
	status, _ := act(t, h.URL, id, a.Token, 1, "move", 0)
	if status != 200 {
		t.Fatal(status)
	}
	status, _ = act(t, h.URL, id, b.Token, 2, "move", 0)
	if status != 422 {
		t.Fatal(status)
	}
}

func TestConcurrentSameRevisionCommitsExactlyOnce(t *testing.T) {
	_, h := testServer(t)
	a, _ := room(t, h.URL)
	var wg sync.WaitGroup
	statuses := make(chan int, 2)
	for point := 0; point < 2; point++ {
		wg.Add(1)
		go func(p int) {
			defer wg.Done()
			status, _ := act(t, h.URL, a.Game.ID, a.Token, 1, "move", p)
			statuses <- status
		}(point)
	}
	wg.Wait()
	close(statuses)
	counts := map[int]int{}
	for status := range statuses {
		counts[status]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatal(counts)
	}
	_, current := call(t, h.URL, "/api/games/"+a.Game.ID, "GET", "", nil)
	if current.Game.Position.Ply != 1 {
		t.Fatal(current)
	}
}

func TestDeadlinePassesAndPersistenceFailure(t *testing.T) {
	s, h := testServer(t)
	a, _ := room(t, h.URL)
	id := a.Game.ID
	now := time.Now().Add(121 * time.Second)
	s.mu.Lock()
	s.Now = func() time.Time { return now }
	s.mu.Unlock()
	_, reply := call(t, h.URL, "/api/games/"+id, "GET", "", nil)
	if reply.Game.Position.Ply != 2 || !reply.Game.Position.Finished {
		t.Fatal("expired players did not pass", reply)
	}
	s, h = testServer(t)
	a, _ = room(t, h.URL)
	s.mu.Lock()
	s.Save = func(*Room) error { return fmt.Errorf("disk failure") }
	s.mu.Unlock()
	status, reply := act(t, h.URL, a.Game.ID, a.Token, 1, "move", 0)
	if status != 500 || !strings.Contains(reply.Error, "no unpersisted update") || !strings.Contains(reply.Error, reply.Events[0].ID) {
		t.Fatal(status, reply)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.rooms[a.Game.ID].Position.Ply != 0 {
		t.Fatal("unpersisted action was published")
	}
}

func TestOriginBodyAndPathBoundaries(t *testing.T) {
	s, h := testServer(t)
	r, _ := http.NewRequest("POST", h.URL+"/api/games", strings.NewReader(`{}`))
	r.Header.Set("Origin", "http://evil.invalid")
	r.Header.Set("Content-Type", "application/json")
	res, e := http.DefaultClient.Do(r)
	if e != nil {
		t.Fatal(e)
	}
	res.Body.Close()
	if res.StatusCode != 403 {
		t.Fatal("foreign origin accepted")
	}
	for _, path := range []string{"/api/games/../../etc/passwd", "/api/games/not-a-room"} {
		status, _ := call(t, h.URL, path, "GET", "", nil)
		if status != 404 {
			t.Fatal(status)
		}
	}
	status, _ := call(t, h.URL, "/api/games", "POST", "", map[string]any{"unknown": "rejected"})
	if status != 400 {
		t.Fatal(status)
	}
	link := filepath.Join(t.TempDir(), "escape")
	if e = os.Symlink(s.root, link); e != nil {
		t.Fatal(e)
	}
	if _, e = New(link); e == nil {
		t.Fatal("symlink runtime accepted")
	}
}

// R6: reject request confusion and DNS rebinding before any room can be created.
func TestStrictJSONAndLoopbackHost(t *testing.T) {
	s, h := testServer(t)
	for _, body := range []string{
		`{"size":5,"size":9,"players":2,"max_turns":200,"name":"A"}`,
		`{"size":5,"Size":9,"players":2,"max_turns":200,"name":"A"}`,
		`{"size":5,"players":2,"name":"` + string([]byte{0xff}) + `"}`,
		`{"unknown":` + strings.Repeat("[", 34) + `0` + strings.Repeat("]", 34) + `}`,
		`{} {}`, `null`, `[]`, strings.Repeat(" ", (1<<20)+1),
	} {
		r, _ := http.NewRequest("POST", h.URL+"/api/games", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		res, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != 400 {
			t.Fatalf("invalid JSON accepted: %d", res.StatusCode)
		}
	}
	r, _ := http.NewRequest("POST", h.URL+"/api/games", strings.NewReader(`{"size":5,"players":2,"max_turns":200,"name":"A"}`))
	r.Header.Set("Content-Type", "application/jsonx")
	badType, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	badType.Body.Close()
	if badType.StatusCode != 400 {
		t.Fatal("lookalike content type accepted")
	}
	r, _ = http.NewRequest("GET", h.URL+"/", nil)
	r.Host = "attacker.example"
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 403 {
		t.Fatal("DNS-rebinding Host accepted")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.rooms) != 0 {
		t.Fatal("bad request created room")
	}
}

func TestGIFReplaysExactSelectedPath(t *testing.T) {
	request := ExportRequest{Size: 5, Players: 4, MaxTurns: 200, Actions: []game.Action{{Kind: "move", Point: 0}, {Kind: "move", Point: 1}, {Kind: "pass"}}}
	frames, e := ReplayExport(request)
	if e != nil {
		t.Fatal(e)
	}
	body, e := EncodeGIF(frames)
	if e != nil {
		t.Fatal(e)
	}
	animation, e := gif.DecodeAll(bytes.NewReader(body))
	if e != nil || len(animation.Image) != 4 || animation.Image[3].Bounds() != RenderFrame(frames[3]).Bounds() {
		t.Fatal("invalid GIF", e)
	}
	if !bytes.Equal(animation.Image[3].Pix, RenderFrame(frames[3]).Pix) {
		t.Fatal("final image differs from selected authoritative state")
	}
	request.Actions = append(request.Actions, game.Action{Kind: "move", Point: 0})
	if _, e = ReplayExport(request); e == nil {
		t.Fatal("export invented an illegal move")
	}
}

// R5/R6: finite storage, no fake artifact, and fail-closed restart.
func TestStorageBoundsAndCorruptRestart(t *testing.T) {
	s, h := testServer(t)
	for i := 0; i < 32; i++ {
		s.rooms[fmt.Sprint(i)] = &Room{}
	}
	status, _ := call(t, h.URL, "/api/games", "POST", "", map[string]any{"size": 5, "players": 2, "max_turns": 200, "name": "A"})
	if status != 429 {
		t.Fatal("room capacity not enforced", status)
	}
	for i := 0; i < 64; i++ {
		if err := os.WriteFile(filepath.Join(s.root, fmt.Sprintf("fixture-%d.gif", i)), []byte("bound fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	r, _ := http.NewRequest("POST", h.URL+"/api/export", strings.NewReader(`{"size":5,"players":2,"max_turns":200,"actions":[]}`))
	r.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 429 || res.Header.Get("X-GoServer-Artifact") != "" {
		t.Fatal("export bound claimed artifact", res.StatusCode)
	}
	if _, err := ReplayExport(ExportRequest{Size: 5, Players: 2, MaxTurns: 512, Actions: make([]game.Action, 201)}); err == nil {
		t.Fatal("oversized export accepted")
	}
	s, h = testServer(t)
	a, _ := room(t, h.URL)
	path := filepath.Join(s.root, a.Game.ID+".json")
	var persisted Room
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(body, &persisted); err != nil {
		t.Fatal(err)
	}
	persisted.Position.Losses[0] = 999
	body, err = json.Marshal(persisted)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = New(s.root); err == nil {
		t.Fatal("corrupt snapshot trusted without replay")
	}
}
