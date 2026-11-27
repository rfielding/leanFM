package goserver

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Requirement refs: property:turns are logged as LeanFM events.
// A bot game writes each turn as one session of the protocol Turn: BotTurn, then BotMoveChosen
// caused by it with the same turnSeq, then Applied or Stale; or Passed or ClockRanOut alone.
func TestBotTurnsAreLoggedAsTurnSessions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "logs", "events.log")
	ev, err := OpenEventLog(path)
	if err != nil {
		t.Fatal(err)
	}
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
	tb.s.SetEventLog(ev)
	tb.s.botBudgetOverride = 10 * time.Millisecond
	tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	waitFor(t, tb, tb.bob, func(g GameState) bool { return g.MoveNo >= 6 })
	tb.s.Close()
	time.Sleep(50 * time.Millisecond)
	ev.Close()

	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	type line struct {
		ID, Session, Protocol, From, To, At, Label, Cause string
		Act                                               bool
		Fields                                            map[string]string
	}
	sessions := map[string][]line{}
	var order []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		text := sc.Text()
		if !strings.HasPrefix(text, `{"type":"leanFM",`) {
			t.Fatalf("a line that is not a LeanFM event line: %s", text)
		}
		for _, secret := range []string{tb.alice, tb.bob} {
			if secret != "" && strings.Contains(text, secret) {
				t.Fatalf("an event line carries a session token: %s", text)
			}
		}
		var l line
		if err := json.Unmarshal([]byte(text), &l); err != nil {
			t.Fatalf("not JSON: %s", text)
		}
		if l.Protocol != "Turn" || l.ID == "" || l.Session == "" {
			t.Fatalf("missing protocol, id or session: %s", text)
		}
		if _, ok := sessions[l.Session]; !ok {
			order = append(order, l.Session)
		}
		sessions[l.Session] = append(sessions[l.Session], l)
	}
	applied := 0
	for _, s := range order {
		ls := sessions[s]
		switch ls[0].Label {
		case "Passed", "ClockRanOut":
			if len(ls) != 1 || !ls[0].Act || ls[0].At != "Server" {
				t.Fatalf("session %s: a server turn is one event at Server: %+v", s, ls)
			}
		case "BotTurn":
			if len(ls) == 1 {
				continue // the last turn, still searching when the game was closed
			}
			if len(ls) != 3 || ls[0].From != "Server" || ls[0].To != "Bot" || ls[1].Label != "BotMoveChosen" ||
				ls[1].Cause != ls[0].ID || ls[1].Fields["turnSeq"] != ls[0].Fields["turnSeq"] ||
				!(ls[2].Label == "Applied" || ls[2].Label == "Stale") || !ls[2].Act {
				t.Fatalf("session %s does not follow Turn: %+v", s, ls)
			}
			if ls[2].Label == "Applied" {
				applied++
			}
		default:
			t.Fatalf("session %s starts with %s", s, ls[0].Label)
		}
	}
	if applied < 6 {
		t.Fatalf("only %d applied bot turns logged for six moves", applied)
	}
}

// A log that cannot be written never stops a game: the failure is counted.
func TestAnUnwritableEventLogNeverStopsAGame(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.log")
	ev, err := OpenEventLog(path)
	if err != nil {
		t.Fatal(err)
	}
	ev.f.Close() // every write now fails
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
	tb.s.SetEventLog(ev)
	tb.s.botBudgetOverride = 10 * time.Millisecond
	tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	waitFor(t, tb, tb.bob, func(g GameState) bool { return g.MoveNo >= 3 })
	if ev.Failures.Load() == 0 {
		t.Fatal("failed writes were not counted")
	}
}
