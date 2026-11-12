package goserver

// Requirement refs: grammar:set_seat_plan, grammar:leave_seat, grammar:set_autopilot,
// task:team_merge, task:bot_turn, task:turn, grammar:game_state and their never-proofs.

import (
	"sync"
	"testing"
	"time"
)

func seatedTable(t *testing.T, seats uint32, people ...string) (*table, map[string]string) {
	t.Helper()
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: seats, MainTimeMS: 60000})
	tok := map[string]string{"alice": tb.alice, "bob": tb.bob}
	for _, name := range []string{"carol", "dave"} {
		tok[name], _ = tb.s.IssueSession(name)
		tb.s.Handle(EnterRoom{SessionID: tok[name], RoomID: "lobby", RequestID: tb.id()})
		tb.s.Handle(JoinGame{SessionID: tok[name], GameID: tb.game, RequestID: tb.id()})
	}
	for i, p := range people {
		if got, ok := tb.s.Handle(TakeSeat{SessionID: tok[p], GameID: tb.game, Seat: uint32(i + 1), RequestID: tb.id()}).(SeatTaken); !ok {
			t.Fatalf("seat %s: %#v", p, got)
		}
	}
	return tb, tok
}

func TestSeatPlanIsTheCreatorsBeforeStart(t *testing.T) {
	tb, tok := seatedTable(t, 3, "alice")
	s := tb.s
	plan := func(who string, seat uint32, ctl string, team uint32) string {
		return code(s.Handle(SetSeatPlan{SessionID: who, GameID: tb.game, Seat: seat, Controller: ctl, Team: team, RequestID: tb.id()}))
	}
	if c := plan(tb.bob, 2, CtlBot, 2); c != "not_creator" {
		t.Fatalf("non-creator planned: %q", c)
	}
	if c := plan(tb.alice, 1, CtlBot, 1); c != "seat_occupied" {
		t.Fatalf("person turned into bot: %q", c)
	}
	if c := plan(tb.alice, 2, CtlBot, 1); c != "" {
		t.Fatalf("plan: %q", c)
	}
	if c := plan(tb.alice, 3, CtlOpen, 9); c != "invalid_seat_plan" {
		t.Fatalf("team out of range: %q", c)
	}
	if c := code(s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, Seat: 2, RequestID: tb.id()})); c != "seat_unavailable" {
		t.Fatalf("took a bot seat: %q", c)
	}
	s.Handle(TakeSeat{SessionID: tok["carol"], GameID: tb.game, Seat: 3, RequestID: tb.id()})
	if got, ok := s.Handle(LeaveSeat{SessionID: tok["carol"], GameID: tb.game, RequestID: tb.id()}).(SeatLeft); !ok || got.Seat != 3 {
		t.Fatalf("leave: %#v", got)
	}
	st := tb.state(t, tb.alice)
	if st.Seats[1].Controller != CtlBot || st.Seats[1].Team != 1 || st.Seats[2].Controller != CtlOpen || len(st.Teams) != 2 {
		t.Fatalf("plan view: %+v", st.Seats)
	}
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	if c := plan(tb.alice, 3, CtlOpen, 3); c != "not_open" {
		t.Fatalf("plan after start: %q", c)
	}
	if c := code(s.Handle(LeaveSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})); c != "not_open" {
		t.Fatalf("leave after start: %q", c)
	}
}

func TestCreateGameSeatPlanAndBotSettings(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 3, ExploreMilli: 1400, RewardMode: "rank", Softness: 8,
		SeatPlan: []SeatPlan{{Seat: 2, Controller: CtlBot, Team: 1}}})
	st := tb.state(t, tb.alice)
	if st.ExploreMilli != 1400 || st.RewardMode != "rank" || st.Softness != 8 || st.Seats[1].Controller != CtlBot || st.Seats[1].Team != 1 {
		t.Fatalf("settings: %+v", st)
	}
	for _, bad := range []CreateGame{{ExploreMilli: 3}, {RewardMode: "x"}, {Softness: 5}, {Seats: 2, SeatPlan: []SeatPlan{{Seat: 3}}}, {Seats: 2, SeatPlan: []SeatPlan{{Seat: 1}, {Seat: 1}}}, {Seats: 2, SeatPlan: []SeatPlan{{Seat: 1, Controller: "god"}}}} {
		bad.SessionID, bad.RoomID, bad.GameName, bad.RequestID = tb.alice, "lobby", "x", tb.id()
		if code(tb.s.Handle(bad)) == "" {
			t.Fatalf("accepted %+v", bad)
		}
	}
}

func waitFor(t *testing.T, tb *table, who string, cond func(GameState) bool) GameState {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if st := tb.state(t, who); cond(st) {
			return st
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not reached")
	return GameState{}
}

func TestAutopilotPlaysMySeatAndGivesItBack(t *testing.T) {
	tb, tok := seatedTable(t, 2, "alice", "bob")
	s := tb.s
	s.botBudgetOverride = 20 * time.Millisecond
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	if c := code(s.Handle(SetAutopilot{SessionID: tok["carol"], GameID: tb.game, On: true, RequestID: tb.id()})); c != "not_seated" {
		t.Fatalf("watcher switched autopilot: %q", c)
	}
	// Alice hands her seat to a bot during her own turn: a bot moves for seat 1.
	s.Handle(SetAutopilot{SessionID: tb.alice, GameID: tb.game, On: true, RequestID: tb.id()})
	st := waitFor(t, tb, tb.alice, func(g GameState) bool { return g.MoveNo >= 1 })
	if st.Moves[0].Source != "autopilot" || st.Moves[0].Search == nil || st.Seats[0].Controller != CtlAutopilot || st.Seats[0].Player != "alice" {
		t.Fatalf("autopilot move: %+v %+v", st.Moves[0], st.Seats[0])
	}
	if c := code(s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 1, Kind: "pass", RequestID: tb.id()})); c != "not_your_turn" {
		t.Fatalf("alice moved for bob: %q", c)
	}
	// Bob moves, then alice takes her seat back during her own turn.
	s.Handle(PlayMove{SessionID: tb.bob, GameID: tb.game, MoveNo: 1, Kind: "place", X: 0, Y: 0, RequestID: tb.id()})
	s.Handle(SetAutopilot{SessionID: tb.alice, GameID: tb.game, On: false, RequestID: tb.id()})
	time.Sleep(80 * time.Millisecond) // a discarded bot result must not land
	st = tb.state(t, tb.alice)
	if st.MoveNo != 2 || st.Seats[0].Controller != CtlPerson {
		t.Fatalf("bot played after take-back: %+v", st.Moves)
	}
	if got, ok := s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 2, Kind: "place", X: 4, Y: 4, RequestID: tb.id()}).(MovePlayed); !ok || got.Seat != 1 {
		t.Fatalf("alice could not move after take-back: %#v", got)
	}
}

func TestMergesNeedEveryPersonsConsent(t *testing.T) {
	tb, tok := seatedTable(t, 4, "alice", "bob", "carol")
	s := tb.s
	s.Handle(SetSeatPlan{SessionID: tb.alice, GameID: tb.game, Seat: 3, Controller: CtlOpen, Team: 2, RequestID: tb.id()}) // bob+carol team 2
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})                                          // seat 4 bot, team 4
	propose := func(who string, other uint32) any {
		return s.Handle(ProposeMerge{SessionID: who, GameID: tb.game, OtherTeam: other, RequestID: tb.id()})
	}
	respond := func(who string, id uint32, ok bool) any {
		return s.Handle(RespondMerge{SessionID: who, GameID: tb.game, ProposalID: id, Accept: ok, RequestID: tb.id()})
	}
	if c := code(propose(tb.alice, 4)); c != "no_person_on_team" {
		t.Fatalf("merged with an all-bot team: %q", c)
	}
	if c := code(propose(tok["dave"], 2)); c != "not_seated" {
		t.Fatalf("watcher proposed: %q", c)
	}
	pr := propose(tb.alice, 2).(MergeProposed)
	if c := code(propose(tb.bob, 1)); c != "duplicate_proposal" {
		t.Fatalf("duplicate: %q", c)
	}
	if c := code(respond(tok["dave"], pr.ProposalID, true)); c != "not_seated" && c != "not_on_team" {
		t.Fatalf("outsider responded: %q", c)
	}
	if got := respond(tb.bob, pr.ProposalID, true).(MergeResponded); got.Status != "pending" {
		t.Fatalf("merged without carol: %+v", got)
	}
	st := tb.state(t, tb.alice)
	if len(st.Proposals) != 1 || len(st.Proposals[0].WaitingFor) != 1 || st.Proposals[0].WaitingFor[0] != "carol" || st.Seats[1].Team != 2 {
		t.Fatalf("pending view: %+v", st.Proposals)
	}
	if got := respond(tok["carol"], pr.ProposalID, false).(MergeResponded); got.Status != "withdrawn" {
		t.Fatalf("decline: %+v", got)
	}
	pr = propose(tb.alice, 2).(MergeProposed)
	respond(tb.bob, pr.ProposalID, true)
	if got := respond(tok["carol"], pr.ProposalID, true).(MergeResponded); got.Status != "merged" {
		t.Fatalf("merge: %+v", got)
	}
	st = tb.state(t, tb.alice)
	if st.Seats[0].Team != 1 || st.Seats[1].Team != 1 || st.Seats[2].Team != 1 || st.Seats[3].Team != 4 || len(st.Teams) != 2 {
		t.Fatalf("merged teams: %+v", st.Seats)
	}
	if c := code(propose(tb.bob, 1)); c != "invalid_team" {
		t.Fatalf("merge undone or repeated: %q", c)
	}
}

func TestTeamChangeAndFinishWithdrawProposals(t *testing.T) {
	tb, tok := seatedTable(t, 3, "alice", "bob", "carol")
	s := tb.s
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	p12 := s.Handle(ProposeMerge{SessionID: tb.alice, GameID: tb.game, OtherTeam: 2, RequestID: tb.id()}).(MergeProposed)
	p23 := s.Handle(ProposeMerge{SessionID: tok["carol"], GameID: tb.game, OtherTeam: 2, RequestID: tb.id()}).(MergeProposed)
	s.Handle(RespondMerge{SessionID: tb.bob, GameID: tb.game, ProposalID: p12.ProposalID, Accept: true, RequestID: tb.id()})
	st := tb.state(t, tb.alice)
	if len(st.Proposals) != 0 {
		t.Fatalf("team change kept proposal %d: %+v", p23.ProposalID, st.Proposals)
	}
	s.Handle(ProposeMerge{SessionID: tok["carol"], GameID: tb.game, OtherTeam: 1, RequestID: tb.id()})
	for i, who := range []string{tb.alice, tb.bob, tok["carol"]} {
		s.Handle(PlayMove{SessionID: who, GameID: tb.game, MoveNo: uint32(i), Kind: "pass", RequestID: tb.id()})
	}
	st = tb.state(t, tb.alice)
	if st.Status != GameFinished || len(st.Proposals) != 0 {
		t.Fatalf("finish kept proposals: %+v", st)
	}
	if c := code(s.Handle(ProposeMerge{SessionID: tok["carol"], GameID: tb.game, OtherTeam: 1, RequestID: tb.id()})); c != "not_playing" {
		t.Fatalf("merge after finish: %q", c)
	}
}

func TestTeamScoresDecideWinners(t *testing.T) {
	v := []SeatView{{Seat: 1, Team: 1, Score: 5}, {Seat: 2, Team: 2, Score: 7}, {Seat: 3, Team: 1, Score: 4}, {Seat: 4, Team: 4, Score: 9, Resigned: true}}
	w := winnersOf(v)
	if len(w) != 2 || w[0] != 1 || w[1] != 3 {
		t.Fatalf("team winners: %v", w)
	}
}

func TestBotMovesPublishSearchSummariesAndStateIsIncremental(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
	tb.s.botBudgetOverride = 15 * time.Millisecond
	tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	st := waitFor(t, tb, tb.bob, func(g GameState) bool { return g.MoveNo >= 4 })
	for _, m := range st.Moves[:4] {
		if m.Search == nil || m.Search.Playouts == 0 || len(m.Search.Candidates) == 0 || len(m.Search.RootProjMilli) != 2 || len(m.Search.Candidates[0].ProjMilli) != 2 {
			t.Fatalf("missing summary: %+v", m)
		}
	}
	part, _ := tb.s.Handle(GetGameState{SessionID: tb.bob, GameID: tb.game, SinceMove: 3, RequestID: tb.id()}).(GameState)
	if len(part.Moves) == 0 || part.Moves[0].MoveNo != 3 {
		t.Fatalf("since_move: %+v", part.Moves)
	}
}

func TestTurnsNeverEndTwice(t *testing.T) {
	for round := 0; round < 20; round++ {
		tb, _ := seatedTable(t, 2, "alice", "bob")
		tb.s.turnLimit = 2 * time.Millisecond
		tb.s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
		var wg sync.WaitGroup
		for i := 0; i < 4; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				tb.s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 0, Kind: "place", X: uint32(i), Y: 0, RequestID: uint64(1000 + i)})
			}(i)
		}
		wg.Wait()
		time.Sleep(5 * time.Millisecond)
		st := tb.state(t, tb.alice)
		seen := map[uint32]bool{}
		for _, m := range st.Moves {
			if seen[m.MoveNo] {
				t.Fatalf("move %d recorded twice: %+v", m.MoveNo, st.Moves)
			}
			seen[m.MoveNo] = true
		}
		stones := 0
		for _, c := range st.Cells {
			if c == 1 {
				stones++
			}
		}
		if stones > 1 {
			t.Fatalf("one turn placed %d stones", stones)
		}
	}
}

func TestBowlRecordsWhoCaptured(t *testing.T) {
	tb, _ := seatedTable(t, 2, "alice", "bob")
	s := tb.s
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	mv := func(who string, no, x, y uint32) {
		if _, ok := s.Handle(PlayMove{SessionID: who, GameID: tb.game, MoveNo: no, Kind: "place", X: x, Y: y, RequestID: tb.id()}).(MovePlayed); !ok {
			t.Fatalf("move %d", no)
		}
	}
	mv(tb.alice, 0, 1, 0)
	mv(tb.bob, 1, 0, 0)   // bob in the corner
	mv(tb.alice, 2, 0, 1) // captures bob's stone
	st := tb.state(t, tb.alice)
	if st.Seats[1].Losses != 1 || st.Seats[1].LossesBy[0] != 1 || st.Moves[2].Victims[1] != 1 {
		t.Fatalf("bowl: %+v %+v", st.Seats[1], st.Moves[2])
	}
}
