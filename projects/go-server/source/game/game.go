// Requirement refs: working-contract.json R1, R2, R4, R6.
package game

import "fmt"

var Colors = []string{"Black", "White", "Red", "Blue", "Green", "Gold"}

type Position struct {
	Size     int    `json:"size"`
	Players  int    `json:"players"`
	Board    []int  `json:"board"`
	Turn     int    `json:"turn"`
	Losses   []int  `json:"losses"`
	Ledger   []int  `json:"ledger"`
	Active   []bool `json:"active"`
	Passes   int    `json:"passes"`
	Ply      int    `json:"ply"`
	MaxTurns int    `json:"max_turns"`
	Finished bool   `json:"finished"`
	Last     int    `json:"last"`
}

type Action struct {
	Kind  string `json:"kind"`
	Point int    `json:"point"`
}

type Scores struct {
	Territory []int `json:"territory"`
	Losses    []int `json:"losses"`
	Total     []int `json:"total"`
}

func New(size, players, maxTurns int) (Position, error) {
	if size < 3 || size > 19 || players < 2 || players > 6 || maxTurns < players || maxTurns > 512 {
		return Position{}, fmt.Errorf("board must be 3..19, players 2..6, and maximum turns players..512")
	}
	active := make([]bool, players)
	for i := range active {
		active[i] = true
	}
	return Position{Size: size, Players: players, Board: make([]int, size*size), Losses: make([]int, players), Ledger: make([]int, players*players), Active: active, MaxTurns: maxTurns, Last: -1}, nil
}

func (s Position) Clone() Position {
	s.Board = append([]int(nil), s.Board...)
	s.Losses = append([]int(nil), s.Losses...)
	s.Ledger = append([]int(nil), s.Ledger...)
	s.Active = append([]bool(nil), s.Active...)
	return s
}

func Neighbors(point, size int) []int {
	n := make([]int, 0, 4)
	if point%size > 0 {
		n = append(n, point-1)
	}
	if point%size < size-1 {
		n = append(n, point+1)
	}
	if point >= size {
		n = append(n, point-size)
	}
	if point < size*(size-1) {
		n = append(n, point+size)
	}
	return n
}

func group(board []int, size, start int) ([]int, bool) {
	color := board[start]
	seen := make([]bool, len(board))
	seen[start] = true
	stones := []int{start}
	liberty := false
	for cursor := 0; cursor < len(stones); cursor++ {
		for _, next := range Neighbors(stones[cursor], size) {
			if board[next] == 0 {
				liberty = true
			}
			if board[next] == color && !seen[next] {
				seen[next] = true
				stones = append(stones, next)
			}
		}
	}
	return stones, liberty
}

func Apply(old Position, action Action) (Position, error) {
	if old.Finished {
		return old, fmt.Errorf("game has finished")
	}
	if old.Turn < 0 || old.Turn >= old.Players || !old.Active[old.Turn] {
		return old, fmt.Errorf("invalid active player")
	}
	if action.Kind != "move" && action.Kind != "pass" && action.Kind != "resign" {
		return old, fmt.Errorf("unknown action; expected move, pass, or resign")
	}
	if action.Kind == "move" && (action.Point < 0 || action.Point >= len(old.Board) || old.Board[action.Point] != 0) {
		return old, fmt.Errorf("intersection is occupied or outside the board")
	}
	s := old.Clone()
	player := s.Turn
	s.Last = -1
	s.Ply++
	switch action.Kind {
	case "pass":
		s.Passes++
	case "resign":
		s.Active[player] = false
		s.Passes = 0
	case "move":
		s.Passes = 0
		s.Last = action.Point
		s.Board[action.Point] = player + 1
		removed := []int{}
		inspected := make([]bool, len(s.Board))
		for _, next := range Neighbors(action.Point, s.Size) {
			if s.Board[next] == 0 || s.Board[next] == player+1 || inspected[next] {
				continue
			}
			stones, liberty := group(s.Board, s.Size, next)
			for _, stone := range stones {
				inspected[stone] = true
			}
			if !liberty {
				removed = append(removed, stones...)
			}
		}
		for _, stone := range removed {
			victim := s.Board[stone] - 1
			s.Losses[victim]++
			s.Ledger[player*s.Players+victim]++
			s.Board[stone] = 0
		}
		if len(removed) == 0 {
			stones, liberty := group(s.Board, s.Size, action.Point)
			if !liberty {
				for _, stone := range stones {
					s.Board[stone] = 0
					s.Losses[player]++
					s.Ledger[player*s.Players+player]--
				}
			}
		}
	}
	count := 0
	for _, active := range s.Active {
		if active {
			count++
		}
	}
	s.Finished = count <= 1 || s.Passes >= count || s.Ply >= s.MaxTurns
	if !s.Finished {
		for {
			s.Turn = (s.Turn + 1) % s.Players
			if s.Active[s.Turn] {
				break
			}
		}
	}
	return s, nil
}

func Score(s Position) Scores {
	territory := make([]int, s.Players)
	seen := make([]bool, len(s.Board))
	for start, color := range s.Board {
		if color != 0 || seen[start] {
			continue
		}
		region := []int{start}
		seen[start] = true
		boundary := map[int]bool{}
		for cursor := 0; cursor < len(region); cursor++ {
			for _, next := range Neighbors(region[cursor], s.Size) {
				if s.Board[next] != 0 {
					boundary[s.Board[next]] = true
				} else if !seen[next] {
					seen[next] = true
					region = append(region, next)
				}
			}
		}
		if len(boundary) == 1 {
			for owner := range boundary {
				territory[owner-1] += len(region)
			}
		}
	}
	total := make([]int, s.Players)
	for i := range total {
		total[i] = territory[i] - s.Losses[i]
	}
	return Scores{Territory: territory, Losses: append([]int(nil), s.Losses...), Total: total}
}
