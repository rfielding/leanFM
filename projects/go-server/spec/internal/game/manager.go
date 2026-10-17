package game

import "fmt"

// PlayerColor identifies a player in an n-player game.
type PlayerColor int

const (
	Black PlayerColor = iota
	White
	Red
	Green
	Blue
	Yellow
)

// For the initial simple server we limit games to two players. This keeps the
// board/turn logic simpler up front. The implementation still retains the
// PlayerColor enums for future expansion.
const MaxPlayers = 2

// Board is a minimal n-player board representation.
type Board struct {
	Size    int
	Players int
	Grid    []int // 0 = empty, 1..Players = player id
}

// NewBoard creates a square board of given size and player count. For the
// initial server the player count is clamped to MaxPlayers.
func NewBoard(size int, players int) *Board {
	if size <= 0 {
		size = 19
	}
	if players <= 0 {
		players = MaxPlayers
	}
	if players > MaxPlayers {
		players = MaxPlayers
	}
	b := &Board{Size: size, Players: players, Grid: make([]int, size*size)}
	return b
}

func (b *Board) idx(r, c int) (int, error) {
	if r < 0 || c < 0 || r >= b.Size || c >= b.Size {
		return 0, fmt.Errorf("out of bounds")
	}
	return r*b.Size + c, nil
}

// PlaceStone places a stone for player (1..Players) at row,col if empty.
func (b *Board) PlaceStone(player int, r, c int) error {
	if player < 1 || player > b.Players {
		return fmt.Errorf("invalid player")
	}
	i, err := b.idx(r, c)
	if err != nil {
		return err
	}
	if b.Grid[i] != 0 {
		return fmt.Errorf("occupied")
	}
	b.Grid[i] = player
	return nil
}
