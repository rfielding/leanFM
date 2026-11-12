package goserver

// Requirement refs: grammar:review_move; property:post-game review is shared and remembered;
// property:chat follows the tree; proof:review never changes the game;
// proof:chat never pins to a position that does not exist.

import (
	"fmt"
	"strconv"
	"strings"
)

const (
	MaxReviewNodes     = 2000
	MaxGameChatEntries = 500
)

// reviewCap is MaxReviewNodes; tests lower it
var reviewCap = MaxReviewNodes

// ReviewNode is one move of a finished game's shared review tree. Parent is a position:
// m<k> (after k actual moves) or another review node r<n>.
type ReviewNode struct {
	ID     string `json:"id"`
	Parent string `json:"parent"`
	Kind   string `json:"kind"` // place or pass
	X      uint32 `json:"x"`
	Y      uint32 `json:"y"`
	Seat   uint32 `json:"seat"`
	Author string `json:"author"`
	TimeMS int64  `json:"timeMs"`
}

type AddReviewMove struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	Parent    string `json:"parent"`
	Kind      string `json:"kind"`
	X         uint32 `json:"x"`
	Y         uint32 `json:"y"`
	RequestID uint64 `json:"requestId"`
}

type ReviewMoveAdded struct {
	GameID    string     `json:"gameId"`
	Node      ReviewNode `json:"node"`
	RequestID uint64     `json:"requestId"`
}

func actualRef(k int) string { return "m" + strconv.Itoa(k) }

// recordMove is the engine move of an actual move record.
func recordMove(geom *Geom, rec MoveRecord) int {
	switch rec.Kind {
	case "place":
		pt, _ := geom.Point(int(rec.X), int(rec.Y))
		return pt
	case "resign":
		return MoveResign
	case "timeout":
		return MoveTimeout
	}
	return MovePass
}

// reviewMove is the engine move of a review node.
func reviewMove(geom *Geom, n ReviewNode) int {
	if n.Kind == "place" {
		pt, _ := geom.Point(int(n.X), int(n.Y))
		return pt
	}
	return MovePass
}

// positionLocked replays the game to a position: an actual position m<k>, or a review node
// with its chain back to the actual position it starts from. ok is false for anything the
// game does not have.
func (g *game) positionLocked(ref string) (*State, bool) {
	p := g.play
	if p == nil {
		return nil, false
	}
	var chain []ReviewNode
	for strings.HasPrefix(ref, "r") {
		i, ok := g.reviewIdx[ref]
		if !ok || len(chain) > MaxReviewNodes {
			return nil, false
		}
		chain = append(chain, g.review[i])
		ref = g.review[i].Parent
	}
	if !strings.HasPrefix(ref, "m") {
		return nil, false
	}
	k, err := strconv.Atoi(ref[1:])
	if err != nil || k < 0 || k > len(p.moves) || ref != actualRef(k) {
		return nil, false
	}
	st := NewState(p.geom, g.seats, p.state.KoOn)
	w := NewWork(p.geom)
	for _, rec := range p.moves[:k] {
		w.Play(st, recordMove(p.geom, rec))
	}
	for i := len(chain) - 1; i >= 0; i-- {
		w.Play(st, reviewMove(p.geom, chain[i]))
	}
	return st, true
}

// pinLocked is the position a chat message is pinned to: the one asked for when the game
// (or, after the finish, its review tree) has it, otherwise the latest actual position.
func (g *game) pinLocked(ref string) string {
	if g.play == nil {
		return actualRef(0)
	}
	latest := actualRef(len(g.play.moves))
	if ref == "" || (strings.HasPrefix(ref, "r") && g.status != GameFinished) {
		return latest
	}
	if _, ok := g.positionLocked(ref); ok {
		return ref
	}
	return latest
}

func (s *ServerCore) addReviewMove(r AddReviewMove) any {
	return s.cached(r.SessionID, "review_move", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "review_move")
		}
		if g.status != GameFinished {
			return reject(r.RequestID, "not_finished", "review_move")
		}
		st, ok := g.positionLocked(r.Parent)
		if !ok {
			return reject(r.RequestID, "no_position", "review_move")
		}
		geom := g.play.geom
		var m int
		switch r.Kind {
		case "pass":
			m = MovePass
		case "place":
			pt, ok := geom.Point(int(r.X), int(r.Y))
			if !ok {
				return reject(r.RequestID, "illegal_move", "review_move")
			}
			m = pt
		default:
			return reject(r.RequestID, "illegal_move", "review_move")
		}
		if geom.Terminal(st) {
			return reject(r.RequestID, "position_over", "review_move")
		}
		if m >= 0 && st.Cells[m] != Open {
			return reject(r.RequestID, "occupied", "review_move")
		}
		if !geom.IsLegal(st, m) {
			return reject(r.RequestID, "ko", "review_move")
		}
		key := fmt.Sprintf("%s|%s|%d|%d", r.Parent, r.Kind, r.X, r.Y)
		if r.Kind == "pass" {
			key = r.Parent + "|pass"
		}
		if id, dup := g.reviewKids[key]; dup {
			return ReviewMoveAdded{GameID: g.id, Node: g.review[g.reviewIdx[id]], RequestID: r.RequestID}
		}
		if len(g.review) >= reviewCap {
			return reject(r.RequestID, "review_full", "review_move")
		}
		n := ReviewNode{ID: "r" + strconv.Itoa(len(g.review)+1), Parent: r.Parent, Kind: r.Kind, Seat: uint32(st.ToMove), Author: identity, TimeMS: s.clock().UnixMilli()}
		if r.Kind == "place" {
			n.X, n.Y = r.X, r.Y
		}
		if g.reviewIdx == nil {
			g.reviewIdx, g.reviewKids = map[string]int{}, map[string]string{}
		}
		g.reviewIdx[n.ID] = len(g.review)
		g.reviewKids[key] = n.ID
		g.review = append(g.review, n)
		return ReviewMoveAdded{GameID: g.id, Node: n, RequestID: r.RequestID}
	})
}
