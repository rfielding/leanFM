package goserver

// Requirement refs: property:byo-yomi clocks; property:bots spend time where it matters;
// proof:clocks never cheat.

import (
	"testing"
	"time"
)

func TestByoyomiChargesMainTimeThenPeriods(t *testing.T) {
	c := clockSpec{main: 10 * time.Second, periods: 3, period: 5 * time.Second}
	st := &seat{mainLeft: c.main, periodsLeft: c.periods}
	if c.limit(st) != 25*time.Second {
		t.Fatalf("limit %v", c.limit(st))
	}
	c.charge(st, 4*time.Second)
	if st.mainLeft != 6*time.Second || st.periodsLeft != 3 {
		t.Fatalf("move in main time: %+v", st)
	}
	// 6 s of main, then 4 s into the first period: the period is kept
	c.charge(st, 10*time.Second)
	if st.mainLeft != 0 || st.periodsLeft != 3 {
		t.Fatalf("move within a period lost it: %+v", st)
	}
	// 12 s: two whole periods run over, the move lands in the third
	c.charge(st, 12*time.Second)
	if st.periodsLeft != 1 {
		t.Fatalf("periods run over: %+v", st)
	}
	main, periods, left := c.stage(st, 2*time.Second)
	if main != 0 || periods != 1 || left != 3*time.Second {
		t.Fatalf("stage: %v %d %v", main, periods, left)
	}
	if _, periods, _ := c.stage(st, 5*time.Second); periods != 0 {
		t.Fatal("the last period ran out but the stage says time remains")
	}
	st.periodsLeft = 3
	c.timedOut(st)
	if st.mainLeft != 0 || st.periodsLeft != 1 {
		t.Fatalf("after a timeout the seat keeps one period: %+v", st)
	}
}

func TestBotPlanNeverUsesUpAPeriod(t *testing.T) {
	c := clockSpec{main: 300 * time.Second, periods: 5, period: 30 * time.Second}
	fresh := &seat{mainLeft: c.main, periodsLeft: c.periods}
	planned, hard := botPlan(c, fresh, 0, 81, 2)
	if planned != 7500*time.Millisecond || hard != 30*time.Second {
		t.Fatalf("early main time: planned %v hard %v", planned, hard)
	}
	low := &seat{mainLeft: 2 * time.Second, periodsLeft: 5}
	planned, hard = botPlan(c, low, 0, 81, 2)
	if planned != 50*time.Millisecond || hard != 15*time.Second || hard >= low.mainLeft+c.period {
		t.Fatalf("main time running out: planned %v hard %v", planned, hard)
	}
	byo := &seat{periodsLeft: 2}
	planned, hard = botPlan(c, byo, 0, 81, 2)
	if planned != 15*time.Second || hard != 24*time.Second {
		t.Fatalf("byo-yomi: planned %v hard %v", planned, hard)
	}
	// already 20 s into the period (an autopilot switch): 10 s left, less a fifth of a period
	planned, hard = botPlan(c, byo, 20*time.Second, 81, 2)
	if hard != 4*time.Second || planned != hard {
		t.Fatalf("late in a period: planned %v hard %v", planned, hard)
	}
	for _, st := range []*seat{fresh, low, byo} {
		for _, el := range []time.Duration{0, time.Second, 29 * time.Second} {
			_, h := botPlan(c, st, el, 40, 4)
			main, _, periodLeft := c.stage(st, el)
			if h > main+periodLeft {
				t.Fatalf("plan runs past the current period: %+v at %v: %v", st, el, h)
			}
		}
	}
}

func TestMovesAreChargedAndAutopilotLeavesTheClock(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2, MainTimeMS: 60000, ByoyomiPeriods: 3, ByoyomiMS: 10000})
	s := tb.s
	base := time.Unix(1_800_000_000, 0)
	now := base
	s.clock = func() time.Time { return now }
	s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	now = now.Add(15 * time.Second)
	s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 0, Kind: "place", X: 2, Y: 2, RequestID: tb.id()})
	st := tb.state(t, tb.bob)
	if st.Seats[0].MainLeftMS != 45000 || st.Seats[0].PeriodsLeft != 3 {
		t.Fatalf("alice after 15 s: %+v", st.Seats[0])
	}
	// bob uses all his main time and 25 s more: two periods run over, the third is kept
	now = now.Add(85 * time.Second)
	if st := tb.state(t, tb.bob); st.RemainingMS != 5000 || st.Seats[1].PeriodsLeft != 1 {
		t.Fatalf("bob's stage: %d ms, %d periods", st.RemainingMS, st.Seats[1].PeriodsLeft)
	}
	before := tb.state(t, tb.bob).RemainingMS
	s.Handle(SetAutopilot{SessionID: tb.bob, GameID: tb.game, On: true, RequestID: tb.id()})
	s.Handle(SetAutopilot{SessionID: tb.bob, GameID: tb.game, On: false, RequestID: tb.id()})
	if after := tb.state(t, tb.bob); after.RemainingMS != before || after.ToMove != 2 {
		t.Fatalf("autopilot switches changed the clock: %d before, %d after", before, after.RemainingMS)
	}
	s.Handle(PlayMove{SessionID: tb.bob, GameID: tb.game, MoveNo: 1, Kind: "pass", RequestID: tb.id()})
	st = tb.state(t, tb.alice)
	if st.Seats[1].MainLeftMS != 0 || st.Seats[1].PeriodsLeft != 1 {
		t.Fatalf("bob after 85 s: %+v", st.Seats[1])
	}
	// alice's whole clock (45 s + 3 x 10 s) runs out: the move loses to the timeout
	now = now.Add(75 * time.Second)
	if c := code(s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 2, Kind: "pass", RequestID: tb.id()})); c != "deadline_passed" {
		t.Fatalf("move after the clock ran out: %q", c)
	}
	st = tb.state(t, tb.alice)
	if st.Moves[2].Kind != "timeout" || st.Seats[0].MainLeftMS != 0 || st.Seats[0].PeriodsLeft != 1 {
		t.Fatalf("timeout: %+v %+v", st.Moves[2], st.Seats[0])
	}
}

func TestSearchStopsEarlyOnSettledMoves(t *testing.T) {
	g := GeomFor(5)
	root := NewState(g, 2, false)
	start := time.Now()
	res := Search(g, root, SearchParams{Budget: 5 * time.Second, Planned: 50 * time.Millisecond, Seed: 1})
	if took := time.Since(start); took > 3*time.Second || (res.Stop != "settled" && res.Stop != "planned") {
		t.Fatalf("managed search ran %v and stopped by %q", took, res.Stop)
	}
	if res.Planned != 50*time.Millisecond || res.Iterations == 0 {
		t.Fatalf("summary: %+v", res)
	}
	// without a plan the search keeps the old behaviour: the whole budget
	res = Search(g, root, SearchParams{Budget: 100 * time.Millisecond, Seed: 1})
	if res.Stop != "limit" {
		t.Fatalf("unmanaged search stopped by %q", res.Stop)
	}
	done := make(chan struct{})
	close(done)
	start = time.Now()
	if res := Search(g, root, SearchParams{Budget: 5 * time.Second, Planned: 4 * time.Second, Cancel: done}); res.Stop != "cancelled" || time.Since(start) > time.Second {
		t.Fatalf("cancelled search: %q after %v", res.Stop, time.Since(start))
	}
}
