package goserver

// Requirement refs: grammar:take_seat, grammar:start_game, grammar:play_move, grammar:game_state
// and their never-proofs.

import (
	"testing"
	"time"
)

type table struct {
	s          *ServerCore
	alice, bob string
	eve        string
	game       string
	n          uint64
}

func newTable(t *testing.T, params CreateGame) *table {
	t.Helper()
	s := NewServer()
	t.Cleanup(s.Close)
	tb := &table{s: s, n: 100}
	tb.alice, _ = s.IssueSession("alice")
	tb.bob, _ = s.IssueSession("bob")
	tb.eve, _ = s.IssueSession("eve")
	for _, who := range []string{tb.alice, tb.bob} {
		s.Handle(EnterRoom{SessionID: who, RoomID: "lobby", RequestID: tb.id()})
	}
	params.SessionID, params.RoomID, params.GameName, params.RequestID = tb.alice, "lobby", "match", tb.id()
	created, ok := s.Handle(params).(GameCreated)
	if !ok {
		t.Fatalf("create: %#v", s.Handle(params))
	}
	tb.game = created.GameID
	s.Handle(JoinGame{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})
	return tb
}

func (tb *table) id() uint64 { tb.n++; return tb.n }

func (tb *table) state(t *testing.T, who string) GameState {
	t.Helper()
	st, ok := tb.s.Handle(GetGameState{SessionID: who, GameID: tb.game, RequestID: tb.id()}).(GameState)
	if !ok {
		t.Fatal("state rejected")
	}
	return st
}

func code(v any) string {
	if r, ok := v.(RequestRejected); ok {
		return r.Code
	}
	return ""
}

func TestCreateGameValidatesBoardParameters(t *testing.T) {
	tb := newTable(t, CreateGame{})
	st := tb.state(t, tb.alice)
	if st.BoardSize != DefaultBoardSize || len(st.Seats) != DefaultSeats || st.TurnDeadlineMS != DefaultTurnDeadlineMS || st.Status != GameOpen {
		t.Fatalf("defaults: %+v", st)
	}
	if st.KoOn {
		t.Fatal("auto ko must be off for four players")
	}
	for _, bad := range []CreateGame{{BoardSize: 8}, {Seats: 9}, {Seats: 1}, {TurnDeadlineMS: 10}, {KoRule: 7}, {BotMS: 99999}} {
		bad.SessionID, bad.RoomID, bad.GameName, bad.RequestID = tb.alice, "lobby", "x", tb.id()
		if code(tb.s.Handle(bad)) == "" {
			t.Fatalf("accepted invalid parameters %+v", bad)
		}
	}
}

func TestSeatsStartAndBotsFillEmptySeats(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 9, Seats: 3})
	s := tb.s
	if c := code(s.Handle(TakeSeat{SessionID: tb.eve, GameID: tb.game, RequestID: tb.id()})); c != "forbidden" {
		t.Fatalf("outsider took a seat: %q", c)
	}
	if got := s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, Seat: 1, RequestID: tb.id()}).(SeatTaken); got.Seat != 1 {
		t.Fatal(got)
	}
	if c := code(s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, Seat: 1, RequestID: tb.id()})); c != "seat_unavailable" {
		t.Fatalf("double seat: %q", c)
	}
	if got := s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()}).(SeatTaken); got.Seat != 2 {
		t.Fatal(got)
	}
	if c := code(s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})); c != "already_seated" {
		t.Fatalf("second seat: %q", c)
	}
	if c := code(s.Handle(StartGame{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})); c != "not_creator" {
		t.Fatalf("non-creator started: %q", c)
	}
	started := s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()}).(GameStarted)
	if !(started.Seats[2].Controller == CtlBot) || started.Seats[2].Player != "bot-3" || (started.Seats[0].Controller == CtlBot) {
		t.Fatalf("bot fill: %+v", started.Seats)
	}
	if c := code(s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})); c != "not_open" {
		t.Fatalf("seat after start: %q", c)
	}
}

func TestMovesAreAuthorizedOrderedAndRuleChecked(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2, KoRule: KoOn})
	s := tb.s
	s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	move := func(who string, no uint32, kind string, x, y uint32) any {
		return s.Handle(PlayMove{SessionID: who, GameID: tb.game, MoveNo: no, Kind: kind, X: x, Y: y, RequestID: tb.id()})
	}
	if c := code(move(tb.bob, 0, "place", 2, 2)); c != "not_your_turn" {
		t.Fatalf("out of turn: %q", c)
	}
	if c := code(move(tb.eve, 0, "place", 2, 2)); c != "forbidden" {
		t.Fatalf("outsider move: %q", c)
	}
	if c := code(move(tb.alice, 3, "place", 2, 2)); c != "stale_move" {
		t.Fatalf("stale: %q", c)
	}
	if c := code(move(tb.alice, 0, "place", 9, 2)); c != "illegal_move" {
		t.Fatalf("off board: %q", c)
	}
	if got := move(tb.alice, 0, "place", 2, 2).(MovePlayed); got.Seat != 1 || got.X != 2 {
		t.Fatal(got)
	}
	if c := code(move(tb.bob, 1, "place", 2, 2)); c != "occupied" {
		t.Fatalf("occupied: %q", c)
	}
	req := PlayMove{SessionID: tb.bob, GameID: tb.game, MoveNo: 1, Kind: "place", X: 0, Y: 0, RequestID: tb.id()}
	first := s.Handle(req).(MovePlayed)
	if again := s.Handle(req).(MovePlayed); again.MoveNo != first.MoveNo || again.X != first.X || again.Seat != first.Seat {
		t.Fatal("replayed move must return the original result without replaying")
	}
	st := tb.state(t, tb.bob)
	if st.MoveNo != 2 || st.Cells[12] != 1 || st.Cells[0] != 2 || st.ToMove != 1 {
		t.Fatalf("state: %+v", st)
	}
	move(tb.alice, 2, "pass", 0, 0)
	move(tb.bob, 3, "pass", 0, 0)
	st = tb.state(t, tb.alice)
	if st.Status != GameFinished || len(st.Winners) == 0 {
		t.Fatalf("not finished: %+v", st)
	}
	if c := code(move(tb.alice, 4, "pass", 0, 0)); c != "not_playing" {
		t.Fatalf("move after end: %q", c)
	}
	if c := code(s.Handle(GetGameState{SessionID: tb.eve, GameID: tb.game, RequestID: tb.id()})); c != "forbidden" {
		t.Fatal("outsider read game state")
	}
}

func TestDeadlineTimesOutAndAbandonmentEnds(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
	tb.s.turnLimit = 40 * time.Millisecond
	tb.s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	tb.s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})
	tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if st := tb.state(t, tb.alice); st.Status == GameFinished {
			if st.Moves[0].Kind != "timeout" || st.EndReason == "" {
				t.Fatalf("end: %+v", st)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timeouts did not end the game")
}

func TestAllBotGamePlaysToTheEnd(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 3})
	tb.s.botBudgetOverride = 5 * time.Millisecond
	tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		st := tb.state(t, tb.bob)
		if st.Status == GameFinished {
			if len(st.Moves) < 3 || len(st.Winners) == 0 {
				t.Fatalf("finished oddly: %+v", st)
			}
			for _, m := range st.Moves {
				if m.Source != "bot" && m.Source != "resigned" {
					t.Fatalf("non-bot move %+v", m)
				}
			}
			hist, _, _ := tb.s.GameChatHistory(tb.alice, tb.game)
			if len(hist) == 0 || hist[len(hist)-1].Sender != "server" {
				t.Fatal("no game-over announcement")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("bot game did not finish")
}

func TestBotNeverMovesForAHuman(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
	tb.s.botBudgetOverride = 5 * time.Millisecond
	tb.s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, Seat: 2, RequestID: tb.id()})
	tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		st := tb.state(t, tb.alice)
		if st.MoveNo >= 1 {
			time.Sleep(50 * time.Millisecond)
			st = tb.state(t, tb.alice)
			if st.MoveNo != 1 || st.ToMove != 2 {
				t.Fatalf("bot played past the human's turn: %+v", st.Moves)
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("bot never opened")
}

func TestLateMoveLosesToTheDeadline(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
	tb.s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	tb.s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})
	tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	base := time.Now()
	tb.s.mu.Lock()
	tb.s.clock = func() time.Time { return base.Add(time.Hour) } // the deadline has passed; the timer has not fired
	tb.s.mu.Unlock()
	got := tb.s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 0, Kind: "place", X: 1, Y: 1, RequestID: tb.id()})
	if code(got) != "deadline_passed" {
		t.Fatalf("late move accepted: %#v", got)
	}
	st := tb.state(t, tb.alice)
	if st.MoveNo != 1 || st.Moves[0].Kind != "timeout" || st.Cells[6] != 0 {
		t.Fatalf("timeout did not win: %+v", st.Moves)
	}
}

func TestSituationalSuperkoUsesExactPositions(t *testing.T) {
	g := GeomFor(5)
	p := &play{geom: g, history: map[uint64][][]byte{}}
	a := NewState(g, 2, true)
	p.remember(a)
	b := a.Clone()
	b.Cells[g.pts[0]] = 1
	b.Hash = a.Hash // forced Zobrist collision with a different board
	if p.seen(b) {
		t.Fatal("a hash collision must not count as a repeated position")
	}
	c := a.Clone()
	c.ToMove = 2
	if p.seen(c) {
		t.Fatal("same board with another seat to move is a different situation")
	}
	if !p.seen(a.Clone()) {
		t.Fatal("identical situation not found")
	}
}
