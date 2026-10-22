package game

import (
	"encoding/json"
	"reflect"
	"testing"
)

// Requirement refs: R1 legal transitions; R2 capture/loss/score consistency.
func fresh(t *testing.T, size, players int) Position {
	t.Helper()
	s, e := New(size, players, 200)
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func move(t *testing.T, s Position, point int) Position {
	t.Helper()
	n, e := Apply(s, Action{Kind: "move", Point: point})
	if e != nil {
		t.Fatal(e)
	}
	return n
}
func TestCaptureAndImmutableInput(t *testing.T) {
	s := fresh(t, 3, 4)
	s.Board = []int{0, 1, 0, 1, 2, 1, 0, 0, 0}
	before, _ := json.Marshal(s)
	next := move(t, s, 7)
	after, _ := json.Marshal(s)
	if string(before) != string(after) {
		t.Fatal("input was mutated")
	}
	if next.Board[4] != 0 || next.Losses[1] != 1 || next.Ledger[1] != 1 {
		t.Fatal(next)
	}
}
func TestEdgeHasNoImmortalLiberty(t *testing.T) {
	s := fresh(t, 3, 2)
	s.Board = []int{2, 0, 0, 1, 0, 0, 0, 0, 0}
	n := move(t, s, 1)
	if n.Board[0] != 0 || n.Losses[1] != 1 {
		t.Fatal("wall incorrectly saved a captured edge stone")
	}
}
func TestSuicideSignedLedger(t *testing.T) {
	s := fresh(t, 3, 4)
	s.Board = []int{0, 2, 0, 3, 0, 4, 0, 2, 0}
	n := move(t, s, 4)
	if n.Board[4] != 0 || n.Losses[0] != 1 || n.Ledger[0] != -1 {
		t.Fatal(n)
	}
}
func TestSeveralGroupsAndOwnGroupCaptureOrder(t *testing.T) {
	s := fresh(t, 3, 3)
	s.Board = []int{2, 1, 3, 0, 2, 1, 2, 1, 3}
	n := move(t, s, 3)
	if n.Board[0] != 0 || n.Board[6] != 0 || n.Board[4] != 0 || n.Board[3] != 1 || n.Losses[1] != 3 {
		t.Fatal(n)
	}
}
func TestRejectedMoveUnchanged(t *testing.T) {
	s := move(t, fresh(t, 3, 2), 4)
	for _, a := range []Action{{"move", 4}, {"move", -1}, {"move", 9}, {"unknown", 0}} {
		n, err := Apply(s, a)
		if err == nil || !reflect.DeepEqual(n, s) {
			t.Fatal("invalid action changed state", a)
		}
	}
}
func TestScoreAndNeutralRegions(t *testing.T) {
	s := fresh(t, 3, 2)
	got := Score(s)
	if got.Total[0] != 0 {
		t.Fatal("empty board belongs to nobody")
	}
	s.Board = []int{1, 1, 1, 1, 0, 1, 1, 1, 1}
	s.Losses[0] = 2
	got = Score(s)
	if got.Territory[0] != 1 || got.Total[0] != -1 {
		t.Fatal(got)
	}
	s.Board[0] = 2
	s.Board[1] = 0
	if Score(s).Territory[0] != 0 {
		t.Fatal("mixed boundary counted as owned")
	}
}
func TestPassRoundAndResign(t *testing.T) {
	s := fresh(t, 11, 4)
	for i := 0; i < 4; i++ {
		n, e := Apply(s, Action{Kind: "pass"})
		if e != nil {
			t.Fatal(e)
		}
		s = n
		if s.Finished != (i == 3) {
			t.Fatal(s)
		}
	}
	s = fresh(t, 3, 2)
	n, e := Apply(s, Action{Kind: "resign"})
	if e != nil || !n.Finished || n.Active[0] {
		t.Fatal(n, e)
	}
}
func TestParameterBounds(t *testing.T) {
	for _, p := range [][3]int{{2, 2, 10}, {20, 2, 10}, {11, 1, 10}, {11, 7, 10}, {11, 2, 513}} {
		if _, e := New(p[0], p[1], p[2]); e == nil {
			t.Fatal(p)
		}
	}
}
