package goserver

// Requirement refs: property:play_move rules; game rules markdown.

import (
	"testing"
	"time"
)

func place(t *testing.T, g *Geom, w *Work, s *State, seat, x, y int) PlayResult {
	t.Helper()
	s.ToMove = seat
	m, ok := g.Point(x, y)
	if !ok || !g.IsLegal(s, m) {
		t.Fatalf("illegal %d,%d for %d", x, y, seat)
	}
	return w.Play(s, m)
}

func TestCaptureCountsVictimLosses(t *testing.T) {
	g := GeomFor(5)
	w := NewWork(g)
	s := NewState(g, 3, false)
	place(t, g, w, s, 2, 1, 1)
	place(t, g, w, s, 1, 0, 1)
	place(t, g, w, s, 1, 2, 1)
	place(t, g, w, s, 3, 1, 0) // a third colour also surrounds
	r := place(t, g, w, s, 1, 1, 2)
	if r.Captured != 1 || s.Losses[2] != 1 || s.Losses[1] != 0 {
		t.Fatalf("capture: %+v losses %v", r, s.Losses)
	}
}

func TestWallBoundsAndSuicideIsLegalButCosts(t *testing.T) {
	g := GeomFor(5)
	w := NewWork(g)
	s := NewState(g, 2, false)
	place(t, g, w, s, 1, 1, 0)
	place(t, g, w, s, 1, 0, 1)
	r := place(t, g, w, s, 2, 0, 0) // corner: walls plus two black stones
	if r.Suicide != 1 || s.Losses[2] != 1 {
		t.Fatalf("suicide: %+v losses %v", r, s.Losses)
	}
	if _, ok := g.Point(5, 0); ok {
		t.Fatal("off-board point accepted")
	}
}

func TestTerritoryMinusLosses(t *testing.T) {
	g := GeomFor(5)
	w := NewWork(g)
	s := NewState(g, 2, false)
	// Black wall on column 1: both empty sides border only Black (5 + 15 points).
	for y := 0; y < 5; y++ {
		place(t, g, w, s, 1, 1, y)
	}
	s.Losses[1] = 2
	sc := w.Score(s, true)
	if sc.Territory[1] != 20 || sc.Scores[1] != 18 || sc.Territory[2] != 0 {
		t.Fatalf("score: terr %v scores %v", sc.Territory, sc.Scores)
	}
	m, _ := g.Point(0, 0)
	if sc.Owner[m] != 1 {
		t.Fatal("owner map")
	}
}

func TestSimpleKo(t *testing.T) {
	g := GeomFor(5)
	w := NewWork(g)
	s := NewState(g, 2, true)
	// classic ko shape around (1,1)/(2,1)
	place(t, g, w, s, 1, 1, 0)
	place(t, g, w, s, 1, 0, 1)
	place(t, g, w, s, 1, 1, 2)
	place(t, g, w, s, 2, 2, 0)
	place(t, g, w, s, 2, 3, 1)
	place(t, g, w, s, 2, 2, 2)
	place(t, g, w, s, 2, 1, 1)
	r := place(t, g, w, s, 1, 2, 1) // black captures at (1,1)
	if r.Captured != 1 {
		t.Fatalf("ko capture: %+v", r)
	}
	m, _ := g.Point(1, 1)
	if s.ToMove != 2 || g.IsLegal(s, m) {
		t.Fatal("immediate ko recapture must be illegal")
	}
}

func TestPassesEndTheGame(t *testing.T) {
	g := GeomFor(5)
	w := NewWork(g)
	s := NewState(g, 3, false)
	for i := 0; i < 3; i++ {
		if g.Terminal(s) {
			t.Fatal("ended early")
		}
		w.Play(s, MovePass)
	}
	if !g.Terminal(s) {
		t.Fatal("all passed but not terminal")
	}
	s2 := NewState(g, 2, false)
	w.Play(s2, MoveTimeout)
	if g.Terminal(s2) {
		t.Fatal("one timeout must not end")
	}
	w.Play(s2, MoveTimeout)
	if !g.Terminal(s2) || !s2.Abandoned() {
		t.Fatal("a full round of timeouts abandons")
	}
}

func TestSearchCapturesAtari(t *testing.T) {
	g := GeomFor(5)
	w := NewWork(g)
	s := NewState(g, 2, false)
	place(t, g, w, s, 2, 2, 2)
	place(t, g, w, s, 1, 1, 2)
	place(t, g, w, s, 1, 3, 2)
	place(t, g, w, s, 1, 2, 1)
	s.ToMove = 1
	res := Search(g, s, SearchParams{Budget: 300 * time.Millisecond, Seed: 1})
	want, _ := g.Point(2, 3)
	if res.Move != want || res.Iterations == 0 {
		x, y := g.XY(res.Move)
		t.Fatalf("expected capture at 2,3, got %d (%d,%d) after %d", res.Move, x, y, res.Iterations)
	}
}

// Requirement refs: property:bot results are bound to their turn (search quality); Implementation gameplay decision on saturated rewards.
func TestWinningBotPassesInsteadOfFillingItsTerritory(t *testing.T) {
	g := GeomFor(5)
	w := NewWork(g)
	s := NewState(g, 2, false)
	// Seat 1 walls off the whole board on column 1 and row 1; seat 2 has nothing.
	for y := 0; y < 5; y++ {
		place(t, g, w, s, 1, 1, y)
	}
	for x := 2; x < 5; x++ {
		place(t, g, w, s, 1, x, 1)
	}
	s.ToMove = 2
	w.Play(s, MovePass) // seat 2 passes; seat 1 to move
	res := Search(g, s, SearchParams{Budget: 300 * time.Millisecond, Seed: 3})
	if res.Move != MovePass {
		x, y := g.XY(res.Move)
		t.Fatalf("a won position should pass, got %d,%d (top %+v)", x, y, res.Top[0])
	}
}
