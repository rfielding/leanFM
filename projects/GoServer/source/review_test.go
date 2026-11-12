package goserver

// Requirement refs: grammar:review_move; property:post-game review is shared and remembered;
// property:chat follows the tree; proof:review never changes the game;
// proof:chat never pins to a position that does not exist.

import "testing"

func TestReviewTreeAfterTheFinish(t *testing.T) {
	tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
	s := tb.s
	s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})
	s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
	review := func(who, parent, kind string, x, y uint32) any {
		return s.Handle(AddReviewMove{SessionID: who, GameID: tb.game, Parent: parent, Kind: kind, X: x, Y: y, RequestID: tb.id()})
	}
	chat := func(who, node, body string) GameChat {
		return s.Handle(SendGameChat{SessionID: who, GameID: tb.game, Body: body, Node: node, RequestID: tb.id()}).(GameChat)
	}
	if c := code(review(tb.alice, "m0", "place", 1, 1)); c != "not_finished" {
		t.Fatalf("review during play: %q", c)
	}
	// during play a remark pins to a position already played, never to a future one or a review node
	if n := chat(tb.bob, "m4", "too early").Node; n != "m0" {
		t.Fatalf("future position: %q", n)
	}
	s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 0, Kind: "place", X: 2, Y: 2, RequestID: tb.id()})
	if n := chat(tb.bob, "r1", "no review yet").Node; n != "m1" {
		t.Fatalf("review node during play: %q", n)
	}
	s.Handle(PlayMove{SessionID: tb.bob, GameID: tb.game, MoveNo: 1, Kind: "pass", RequestID: tb.id()})
	s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 2, Kind: "pass", RequestID: tb.id()})
	before := tb.state(t, tb.alice)
	if before.Status != GameFinished {
		t.Fatal("not finished")
	}
	// the server's game-over notice is pinned to the final position, not the empty board
	hist, _, _ := s.GameChatHistory(tb.alice, tb.game)
	if last := hist[len(hist)-1]; last.Sender != "server" || last.Node != "m3" {
		t.Fatalf("game-over notice pinned to %q", last.Node)
	}
	// bob goes back to after alice's stone and tries a stone of his own instead of passing
	got, ok := review(tb.bob, "m1", "place", 0, 0).(ReviewMoveAdded)
	if !ok || got.Node.ID != "r1" || got.Node.Seat != 2 || got.Node.Author != "bob" {
		t.Fatalf("review move: %#v", got)
	}
	if again := review(tb.alice, "m1", "place", 0, 0).(ReviewMoveAdded); again.Node.ID != "r1" {
		t.Fatal("the same move after the same position made a second node")
	}
	for _, bad := range []struct {
		who, parent, kind string
		x, y              uint32
		code              string
	}{
		{tb.alice, "r1", "place", 2, 2, "occupied"},
		{tb.alice, "m9", "pass", 0, 0, "no_position"},
		{tb.alice, "r99", "pass", 0, 0, "no_position"},
		{tb.alice, "x1", "pass", 0, 0, "no_position"},
		{tb.alice, "m3", "pass", 0, 0, "position_over"},
		{tb.alice, "r1", "place", 7, 7, "illegal_move"},
		{tb.alice, "r1", "resign", 0, 0, "illegal_move"},
		{tb.eve, "m1", "pass", 0, 0, "forbidden"},
	} {
		if c := code(review(bad.who, bad.parent, bad.kind, bad.x, bad.y)); c != bad.code {
			t.Fatalf("review %s %s %d,%d: %q want %q", bad.parent, bad.kind, bad.x, bad.y, c, bad.code)
		}
	}
	if pass, ok := review(tb.alice, "r1", "pass", 0, 0).(ReviewMoveAdded); !ok || pass.Node.ID != "r2" || pass.Node.Parent != "r1" || pass.Node.Seat != 1 {
		t.Fatalf("pass in the review: %#v", pass)
	}
	// "back up and say this was the losing move": pinned to that position
	if n := chat(tb.alice, "m1", "this was the losing move").Node; n != "m1" {
		t.Fatalf("remark on an earlier position: %q", n)
	}
	if n := chat(tb.bob, "r2", "better here").Node; n != "r2" {
		t.Fatalf("remark on a review node: %q", n)
	}
	if n := chat(tb.bob, "r42", "nowhere").Node; n != "m3" {
		t.Fatalf("unknown review node: %q", n)
	}
	// everyone sees the review; the game itself is unchanged
	after := tb.state(t, tb.bob)
	if after.ReviewCount != 2 || len(after.Review) != 2 || after.Review[1].ID != "r2" {
		t.Fatalf("review in GameState: %+v", after.Review)
	}
	if st, _ := tb.s.Handle(GetGameState{SessionID: tb.bob, GameID: tb.game, SinceReview: 1, RequestID: tb.id()}).(GameState); len(st.Review) != 1 || st.Review[0].ID != "r2" {
		t.Fatal("since_review")
	}
	if len(after.Moves) != len(before.Moves) || after.EndReason != before.EndReason || len(after.Winners) != len(before.Winners) || after.Cells[12] != before.Cells[12] {
		t.Fatal("the review changed the game")
	}
	reviewCap = 2
	defer func() { reviewCap = MaxReviewNodes }()
	if c := code(review(tb.alice, "m1", "place", 4, 4)); c != "review_full" {
		t.Fatalf("past the cap: %q", c)
	}
}
