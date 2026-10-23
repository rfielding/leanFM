// Requirement refs: working-contract.json R1, R3, R5, R6.
package server

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"leanfm/goserver/game"
)

//go:embed web/*
var web embed.FS

type Event struct {
	ID       string   `json:"id"`
	CauseID  string   `json:"cause_id"`
	PriorIDs []string `json:"prior_ids"`
	Session  string   `json:"session"`
	Task     string   `json:"task"`
	Src      string   `json:"src"`
	Dst      string   `json:"dst"`
	Message  string   `json:"message"`
	TimeMS   int64    `json:"time_ms"`
}

type Room struct {
	ID         string          `json:"id"`
	Names      []string        `json:"names"`
	Verifiers  []string        `json:"verifiers,omitempty"`
	Position   game.Position   `json:"position"`
	History    []game.Position `json:"history,omitempty"`
	Actions    []game.Action   `json:"actions,omitempty"`
	Revision   int             `json:"revision"`
	DeadlineMS int64           `json:"deadline_ms"`
}
type Reply struct {
	Game   *Room   `json:"game,omitempty"`
	Token  string  `json:"token,omitempty"`
	Seat   *int    `json:"seat,omitempty"`
	Error  string  `json:"error,omitempty"`
	Events []Event `json:"events"`
}
type Server struct {
	mu    sync.Mutex
	rooms map[string]*Room
	root  string
	Now   func() time.Time
	Save  func(*Room) error
}

func nonce() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func verifier(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

var roomID = regexp.MustCompile(`^[a-f0-9]{48}$`)

func New(root string) (*Server, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(abs, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(abs)
	if err != nil || info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("runtime root must be a real directory, not a symlink")
	}
	s := &Server{rooms: map[string]*Room{}, root: abs, Now: time.Now}
	s.Save = s.save
	files, err := os.ReadDir(abs)
	if err != nil {
		return nil, err
	}
	for _, file := range files {
		id := strings.TrimSuffix(file.Name(), ".json")
		if file.Type()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("symlink in runtime root")
		}
		if !strings.HasSuffix(file.Name(), ".json") || !roomID.MatchString(id) {
			continue
		}
		if len(s.rooms) >= 32 {
			return nil, fmt.Errorf("runtime exceeds 32-game limit")
		}
		body, e := os.ReadFile(filepath.Join(abs, file.Name()))
		if e != nil {
			return nil, e
		}
		var room Room
		if e = json.Unmarshal(body, &room); e != nil || room.ID != id {
			return nil, fmt.Errorf("invalid room snapshot: %s", file.Name())
		}
		if _, e = game.New(room.Position.Size, room.Position.Players, room.Position.MaxTurns); e != nil {
			return nil, e
		}
		if len(room.Names) > room.Position.Players || len(room.Verifiers) != len(room.Names) || len(room.History) != len(room.Actions)+1 {
			return nil, fmt.Errorf("inconsistent room snapshot")
		}
		replayed, _ := game.New(room.Position.Size, room.Position.Players, room.Position.MaxTurns)
		if len(room.Names) < 1 || !reflect.DeepEqual(room.History[0], replayed) {
			return nil, fmt.Errorf("invalid initial room snapshot")
		}
		for i, action := range room.Actions {
			replayed, e = game.Apply(replayed, action)
			if e != nil || !reflect.DeepEqual(replayed, room.History[i+1]) {
				return nil, fmt.Errorf("room history replay failed at action %d", i+1)
			}
		}
		if !reflect.DeepEqual(replayed, room.Position) || room.Revision != len(room.Names)-1+len(room.Actions) {
			return nil, fmt.Errorf("snapshot is not the replayed authoritative position")
		}
		s.rooms[id] = &room
	}
	return s, nil
}

func (s *Server) save(room *Room) error {
	body, err := json.Marshal(room)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(s.root, "snapshot-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err = f.Write(body); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(s.root, room.ID+".json"))
}

func clone(room *Room) *Room {
	n := *room
	n.Names = append([]string{}, room.Names...)
	n.Verifiers = append([]string{}, room.Verifiers...)
	n.History = append([]game.Position{}, room.History...)
	n.Actions = append([]game.Action{}, room.Actions...)
	return &n
}
func public(room *Room, history bool) *Room {
	n := clone(room)
	n.Verifiers = nil
	if !history {
		n.History = nil
		n.Actions = nil
	}
	return n
}

func (s *Server) commit(room *Room) error {
	if err := s.Save(room); err != nil {
		return err
	}
	s.rooms[room.ID] = room
	return nil
}

func (s *Server) expire(room *Room) (*Room, error) {
	if room.Position.Finished || len(room.Names) < room.Position.Players || room.DeadlineMS > s.Now().UnixMilli() {
		return room, nil
	}
	n := clone(room)
	for !n.Position.Finished && n.DeadlineMS <= s.Now().UnixMilli() {
		position, err := game.Apply(n.Position, game.Action{Kind: "pass"})
		if err != nil {
			return nil, err
		}
		n.Position = position
		n.History = append(n.History, position)
		n.Actions = append(n.Actions, game.Action{Kind: "pass"})
		n.Revision++
		n.DeadlineMS += 60000
	}
	return n, s.commit(n)
}

func decode(w http.ResponseWriter, r *http.Request, value any) error {
	mediaType, _, mediaErr := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaErr != nil || mediaType != "application/json" {
		return fmt.Errorf("Content-Type must be application/json")
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("JSON request exceeds the byte limit or could not be read")
	}
	if !utf8.Valid(body) || len(bytes.TrimSpace(body)) == 0 || bytes.TrimSpace(body)[0] != '{' {
		return fmt.Errorf("request must be a UTF-8 JSON object")
	}
	check := json.NewDecoder(bytes.NewReader(body))
	if err = checkJSON(check, 0, reflect.TypeOf(value).Elem()); err != nil {
		return err
	}
	if _, err = check.Token(); err != io.EOF {
		return fmt.Errorf("expected exactly one JSON object")
	}
	d := json.NewDecoder(bytes.NewReader(body))
	d.DisallowUnknownFields()
	if err := d.Decode(value); err != nil {
		return fmt.Errorf("invalid JSON request: %v", err)
	}
	if err := d.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("expected exactly one JSON object")
	}
	return nil
}

func checkJSON(d *json.Decoder, depth int, typ reflect.Type) error {
	if depth > 32 {
		return fmt.Errorf("JSON nesting exceeds 32 levels")
	}
	token, err := d.Token()
	if err != nil {
		return fmt.Errorf("invalid JSON syntax")
	}
	if token == json.Delim('{') {
		if typ.Kind() != reflect.Struct {
			return fmt.Errorf("unexpected JSON object")
		}
		fields := map[string]reflect.Type{}
		for i := 0; i < typ.NumField(); i++ {
			field := typ.Field(i)
			fields[strings.Split(field.Tag.Get("json"), ",")[0]] = field.Type
		}
		seen := map[string]bool{}
		for d.More() {
			key, e := d.Token()
			if e != nil {
				return fmt.Errorf("invalid JSON object")
			}
			name, ok := key.(string)
			if !ok || seen[name] {
				return fmt.Errorf("duplicate or invalid JSON field")
			}
			seen[name] = true
			childType, known := fields[name]
			if !known {
				return fmt.Errorf("unknown JSON field %q", name)
			}
			if e = checkJSON(d, depth+1, childType); e != nil {
				return e
			}
		}
		_, err = d.Token()
	}
	if token == json.Delim('[') {
		if typ.Kind() != reflect.Slice {
			return fmt.Errorf("unexpected JSON array")
		}
		for d.More() {
			if err = checkJSON(d, depth+1, typ.Elem()); err != nil {
				return err
			}
		}
		_, err = d.Token()
	}
	if err != nil {
		return fmt.Errorf("invalid JSON syntax")
	}
	return nil
}
func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, e := url.Parse(origin)
	return e == nil && u.Scheme == "http" && u.Host == r.Host
}

func (s *Server) Handler() http.Handler {
	assets, _ := fs.Sub(web, "web")
	files := http.FileServer(http.FS(assets))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; worker-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		ip := net.ParseIP(strings.Trim(host, "[]"))
		if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			http.Error(w, "loopback Host required; DNS rebinding rejected", http.StatusForbidden)
			return
		}
		if r.URL.Path == "/health" {
			w.Write([]byte("ok\n"))
			return
		}
		if r.Method != "GET" && r.Method != "POST" {
			http.Error(w, "method not allowed", 405)
			return
		}
		if r.Method == "POST" && !sameOrigin(r) {
			http.Error(w, "cross-origin mutation rejected", 403)
			return
		}
		if r.URL.Path == "/api/export" && r.Method == "POST" {
			s.export(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			s.api(w, r)
			return
		}
		if r.URL.Path == "/openapi.yaml" {
			w.Header().Set("Content-Type", "application/yaml")
		}
		files.ServeHTTP(w, r)
	})
}

func (s *Server) api(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	task, command := "inspect_game", "InspectGame"
	if r.URL.Path == "/api/games" && r.Method == "POST" {
		task, command = "create_game", "CreateGame"
	}
	if len(parts) == 4 {
		switch parts[3] {
		case "join":
			task, command = "join_game", "JoinGame"
		case "actions":
			task, command = "play_turn", "MakeMove"
		case "history":
			task, command = "inspect_history", "InspectHistory"
		}
	}
	requestID := nonce()
	session := "anonymous"
	if len(parts) > 2 {
		session = parts[2]
	}
	start := Event{ID: requestID, PriorIDs: []string{}, Session: session, Task: task, Src: "Client", Dst: "GoServer", Message: command, TimeMS: s.Now().UnixMilli()}
	respond := func(status int, reply Reply, names ...string) {
		previous := requestID
		reply.Events = []Event{start}
		for _, name := range names {
			ev := Event{ID: nonce(), CauseID: requestID, PriorIDs: []string{previous}, Session: session, Task: task, Src: "GoServer", Dst: "Client", Message: name, TimeMS: s.Now().UnixMilli()}
			reply.Events = append(reply.Events, ev)
			previous = ev.ID
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(reply)
	}
	fail := func(status int, message string) { respond(status, Reply{Error: message}, "ErrorEvent") }
	failed := func(operation string, err error) {
		log.Printf("request_id=%s task=%s operation=%q error=%q", requestID, task, operation, err.Error())
		fail(500, operation+" failed; no unpersisted update was published. Diagnostic request_id="+requestID)
	}
	if task == "create_game" {
		var body struct {
			Size     int    `json:"size"`
			Players  int    `json:"players"`
			MaxTurns int    `json:"max_turns"`
			Name     string `json:"name"`
		}
		if err := decode(w, r, &body); err != nil {
			fail(400, err.Error())
			return
		}
		if len(s.rooms) >= 32 {
			fail(429, "32-game capacity reached; restart with a fresh project-local runtime directory")
			return
		}
		position, err := game.New(body.Size, body.Players, body.MaxTurns)
		if err != nil {
			fail(400, err.Error())
			return
		}
		if len(strings.TrimSpace(body.Name)) < 1 || len(body.Name) > 48 {
			fail(400, "player name must contain 1..48 bytes")
			return
		}
		token := nonce()
		room := &Room{ID: nonce(), Names: []string{body.Name}, Verifiers: []string{verifier(token)}, Position: position, History: []game.Position{position}, Actions: []game.Action{}}
		if err = s.commit(room); err != nil {
			failed("create snapshot persistence", err)
			return
		}
		seat := 0
		respond(201, Reply{Game: public(room, false), Token: token, Seat: &seat}, "GameCreated")
		return
	}
	if len(parts) < 3 || parts[1] != "games" || !roomID.MatchString(parts[2]) {
		fail(404, "unknown game route")
		return
	}
	room, ok := s.rooms[parts[2]]
	if !ok {
		fail(404, "game not found")
		return
	}
	if task == "join_game" && r.Method == "POST" {
		var body struct {
			Name string `json:"name"`
		}
		if err := decode(w, r, &body); err != nil {
			fail(400, err.Error())
			return
		}
		if len(body.Name) < 1 || len(body.Name) > 48 || len(room.Names) >= room.Position.Players {
			fail(409, "game is full or player name is invalid")
			return
		}
		n := clone(room)
		token := nonce()
		seat := len(n.Names)
		n.Names = append(n.Names, body.Name)
		n.Verifiers = append(n.Verifiers, verifier(token))
		n.Revision++
		if len(n.Names) == n.Position.Players {
			n.DeadlineMS = s.Now().Add(time.Minute).UnixMilli()
		}
		if err := s.commit(n); err != nil {
			failed("join snapshot persistence", err)
			return
		}
		respond(200, Reply{Game: public(n, false), Token: token, Seat: &seat}, "Joined")
		return
	}
	if r.Method == "GET" && (len(parts) == 3 || task == "inspect_history") {
		n, err := s.expire(room)
		if err != nil {
			failed("deadline Pass persistence", err)
			return
		}
		respond(200, Reply{Game: public(n, task == "inspect_history")}, map[bool]string{true: "HistoryReturned", false: "GameState"}[task == "inspect_history"])
		return
	}
	if task != "play_turn" || r.Method != "POST" {
		fail(404, "unknown game operation")
		return
	}
	var body struct {
		Revision int         `json:"revision"`
		Action   game.Action `json:"action"`
	}
	if err := decode(w, r, &body); err != nil {
		fail(400, err.Error())
		return
	}
	switch body.Action.Kind {
	case "pass":
		start.Message = "Pass"
	case "resign":
		start.Message = "Resign"
	}
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	seat := -1
	if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") && len(token) == 48 {
		hash := verifier(token)
		for i, v := range room.Verifiers {
			if subtle.ConstantTimeCompare([]byte(hash), []byte(v)) == 1 {
				seat = i
			}
		}
	}
	if seat < 0 {
		fail(401, "a valid game-seat token is required")
		return
	}
	if len(room.Names) < room.Position.Players {
		fail(409, "waiting for all players to join")
		return
	}
	n, err := s.expire(room)
	if err != nil {
		failed("deadline Pass persistence", err)
		return
	}
	room = n
	rejectAction := func(status int, message string) {
		respond(status, Reply{Error: message, Game: public(room, false)}, "ErrorEvent")
	}
	if room.Position.Finished {
		rejectAction(409, "game is complete; no further actions are allowed")
		return
	}
	if body.Revision != room.Revision {
		rejectAction(409, "stale game revision; refresh before playing")
		return
	}
	if seat != room.Position.Turn {
		rejectAction(403, "only the current player may act")
		return
	}
	position, err := game.Apply(room.Position, body.Action)
	if err != nil {
		fail(422, err.Error())
		return
	}
	n = clone(room)
	n.Position = position
	n.History = append(n.History, position)
	n.Actions = append(n.Actions, body.Action)
	n.Revision++
	n.DeadlineMS = s.Now().Add(time.Minute).UnixMilli()
	if err = s.commit(n); err != nil {
		failed("action snapshot persistence", err)
		return
	}
	respond(200, Reply{Game: public(n, false)}, "MoveEvent", "GameState")
}
