package goserver

// Requirement refs: property:turns are logged as LeanFM events (LeanFM's selfhost.project.logs).
//
// GoServer logs as every LeanFM project app does: one LeanFM event line per protocol message,
// appended to logs/events.log under the project root, so LeanFM's MCP tools read it by the name
// GoServer/events and check it against the protocol while games run. Writing is best effort: a
// failure is counted and never reaches a game. No line carries a password, token or session id.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// EventLog appends event lines to one file.
type EventLog struct {
	mu       sync.Mutex
	f        *os.File
	n        atomic.Uint64
	Failures atomic.Uint64
}

// DefaultEventLogPath is logs/events.log in the project whose source directory is cwd.
func DefaultEventLogPath(cwd string) (string, error) {
	project := filepath.Clean(filepath.Join(cwd, ".."))
	if _, err := os.Stat(filepath.Join(project, "spec", "runtime.json")); err != nil {
		return "", errors.New("set GOSERVER_EVENT_LOG: the working directory is not the project's source directory")
	}
	return filepath.Join(project, "logs", "events.log"), nil
}

// OpenEventLog opens path for appending, creating its directory.
func OpenEventLog(path string) (*EventLog, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	return &EventLog{f: f}, nil
}

// Close closes the file.
func (l *EventLog) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.f.Close()
}

// event is one line's fields after the marker, in the order LeanFM writes them.
type event struct {
	ID       string            `json:"id"`
	TS       string            `json:"ts"`
	Session  string            `json:"session"`
	Protocol string            `json:"protocol"`
	From     string            `json:"from,omitempty"`
	To       string            `json:"to,omitempty"`
	At       string            `json:"at,omitempty"`
	Act      bool              `json:"act,omitempty"`
	Label    string            `json:"label"`
	Cause    string            `json:"cause,omitempty"`
	Fields   map[string]string `json:"fields,omitempty"`
}

// write numbers e, appends it as one line and returns its id ("" when the log is off).
func (l *EventLog) write(e event) string {
	if l == nil {
		return ""
	}
	e.ID = "goserver:" + strconv.FormatUint(l.n.Add(1), 10)
	e.TS = strconv.FormatInt(time.Now().UnixNano(), 10)
	b, err := json.Marshal(e)
	if err != nil {
		l.Failures.Add(1)
		return e.ID
	}
	line := append([]byte(`{"type":"leanFM",`), b[1:]...)
	line = append(line, '\n')
	l.mu.Lock()
	_, err = l.f.Write(line)
	l.mu.Unlock()
	if err != nil {
		l.Failures.Add(1)
	}
	return e.ID
}

// SetEventLog turns on the event log (main does; tests may).
func (s *ServerCore) SetEventLog(l *EventLog) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = l
	s.turnCause = make(map[string]string)
}

func turnSession(gameID string, seq uint64) string { return gameID + ":t" + strconv.FormatUint(seq, 10) }

func num(n int) string { return strconv.Itoa(n) }

// logBotTurnLocked writes BotTurn for the turn's first bot dispatch (an autopilot rearm of the same
// turn writes nothing more). Called under s.mu.
func (s *ServerCore) logBotTurnLocked(g *game, seq uint64, seat, moveNo int, budget time.Duration) {
	if s.events == nil {
		return
	}
	key := turnSession(g.id, seq)
	if _, ok := s.turnCause[key]; ok {
		return
	}
	s.turnCause[key] = s.events.write(event{Session: key, Protocol: "Turn", From: "Server", To: "Bot", Label: "BotTurn",
		Fields: map[string]string{"turnSeq": strconv.FormatUint(seq, 10), "seat": num(seat), "moveNo": num(moveNo), "budgetMs": num(int(budget / time.Millisecond))}})
}

// logBotResultLocked writes BotMoveChosen (caused by the turn's BotTurn) and then Applied or Stale.
func (s *ServerCore) logBotResultLocked(job botJob, res SearchResult, applied bool) {
	if s.events == nil {
		return
	}
	key := turnSession(job.gameID, job.seq)
	cause, ok := s.turnCause[key]
	if !ok {
		return
	}
	delete(s.turnCause, key)
	kind, x, y := "pass", 0, 0
	if res.Move >= 0 && job.geom != nil {
		xx, yy := job.geom.XY(res.Move)
		kind, x, y = "place", xx, yy
	}
	s.events.write(event{Session: key, Protocol: "Turn", From: "Bot", To: "Server", Label: "BotMoveChosen", Cause: cause,
		Fields: map[string]string{"turnSeq": strconv.FormatUint(job.seq, 10), "kind": kind, "x": num(x), "y": num(y)}})
	label := "Stale"
	if applied {
		label = "Applied"
	}
	s.events.write(event{Session: key, Protocol: "Turn", At: "Server", Act: true, Label: label})
}

// logServerTurnLocked writes a turn the server ends itself (Passed, ClockRanOut), unless a bot was
// asked to play it: that turn is a BotTurnP and ends as Applied or Stale.
func (s *ServerCore) logServerTurnLocked(g *game, seq uint64, label string) {
	if s.events == nil {
		return
	}
	key := turnSession(g.id, seq)
	if _, ok := s.turnCause[key]; ok {
		return
	}
	s.events.write(event{Session: key, Protocol: "Turn", At: "Server", Act: true, Label: label})
}
