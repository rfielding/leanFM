package goserver

// Requirement refs: property:byo-yomi clocks; property:bots spend time where it matters;
// proof:clocks never cheat; property:turns always end.

import "time"

// Japanese byo-yomi for every seat, person or bot: main time, then periods of equal length.
const (
	DefaultMainTimeMS     = 300000
	DefaultByoyomiPeriods = 5
	DefaultByoyomiMS      = 30000
	// botMargin keeps a bot's search clear of the end of a period
	botMargin = 150 * time.Millisecond
)

var allowedMainTime = map[uint64]bool{60000: true, 300000: true, 600000: true, 1200000: true, 1800000: true, 3600000: true}
var allowedPeriods = map[uint32]bool{1: true, 3: true, 5: true, 10: true}
var allowedPeriodMS = map[uint64]bool{10000: true, 20000: true, 30000: true, 60000: true}

// clockSpec is one game's clock; tests may override it with shorter values.
type clockSpec struct {
	main    time.Duration
	periods int
	period  time.Duration
}

func (s *ServerCore) clockOf(g *game) clockSpec {
	if s.turnLimit > 0 { // test hook: straight byo-yomi with one short period
		return clockSpec{main: 0, periods: 1, period: s.turnLimit}
	}
	return clockSpec{main: time.Duration(g.mainTimeMs) * time.Millisecond, periods: int(g.byoyomiPeriods), period: time.Duration(g.byoyomiMs) * time.Millisecond}
}

// limit is how long the seat may take on this turn, from the start of the turn.
func (c clockSpec) limit(st *seat) time.Duration {
	return st.mainLeft + time.Duration(st.periodsLeft)*c.period
}

// stage is what the seat has left at elapsed into its turn: main time, or the current
// period and how many periods remain including it.
func (c clockSpec) stage(st *seat, elapsed time.Duration) (mainLeft time.Duration, periods int, periodLeft time.Duration) {
	if elapsed < st.mainLeft {
		return st.mainLeft - elapsed, st.periodsLeft, c.period
	}
	over := elapsed - st.mainLeft
	used := int(over / c.period)
	periods = st.periodsLeft - used
	if periods <= 0 {
		return 0, 0, 0
	}
	return 0, periods, c.period - over%c.period
}

// charge takes a move made elapsed into the turn off the seat's clock: main time first; a
// move within a period keeps it; every period run over is used up.
func (c clockSpec) charge(st *seat, elapsed time.Duration) {
	if elapsed <= st.mainLeft {
		st.mainLeft -= elapsed
		return
	}
	over := elapsed - st.mainLeft
	st.mainLeft = 0
	st.periodsLeft -= int(over / c.period)
	if st.periodsLeft < 1 {
		st.periodsLeft = 1
	}
}

// timedOut is the clock after the last period ran over: the seat keeps one period.
func (c clockSpec) timedOut(st *seat) {
	st.mainLeft = 0
	st.periodsLeft = 1
}

// botPlan is how long a bot means to think (planned) and may think at most (hard) on a
// turn, already elapsed into it. In main time it takes a share of what remains by the
// moves it still expects to play, and may stretch a close call to four shares, or into
// most of one period once main time runs short; in byo-yomi it plans half a period. It
// never plans to use up a period.
func botPlan(c clockSpec, st *seat, elapsed time.Duration, empty, seats int) (planned, hard time.Duration) {
	margin := min(botMargin, c.period/10)
	mainLeft, periods, periodLeft := c.stage(st, elapsed)
	if periods == 0 {
		return 0, 0
	}
	if mainLeft > 0 {
		moves := max(8, empty/max(1, seats))
		planned = mainLeft / time.Duration(moves)
		cap := mainLeft + c.period*8/10 - margin
		hard = min(max(4*planned, c.period/2), cap)
	} else {
		hard = max(20*time.Millisecond, periodLeft-max(c.period/5, margin))
		planned = c.period / 2
	}
	planned = min(planned, hard)
	return planned, hard
}

func (s *ServerCore) botBudget(planned, hard time.Duration) (time.Duration, time.Duration) {
	if s.botBudgetOverride > 0 { // test hook: quick bots
		return min(planned, s.botBudgetOverride), min(hard, s.botBudgetOverride)
	}
	return planned, hard
}
