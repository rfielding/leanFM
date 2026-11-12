package goserver

// Requirement refs: property:ranking is computed from rated games;
// proof:ranking never counts what it should not.

import (
	"math"
	"sort"
	"strings"
)

// Comparison weights are integers in units of 1/(2*720720): 720720 = lcm(1..16) and a
// team-size product |A|*|B| is at most 16 with eight seats, so every weight 1/(|A||B|)
// and every half of one (a tie) is exact, and sums never depend on the order of games.
const (
	weightUnit   = 2 * 720720
	AnchorElo    = 1500.0
	fitRounds    = 10000
	fitTolerance = 1e-12
)

type RankEntry struct {
	Rank   uint32 `json:"rank"`
	Player string `json:"player"`
	Kind   string `json:"kind"`
	Rating int32  `json:"rating"`
	Games  uint32 `json:"games"`
	Firsts uint32 `json:"firsts"`
	claim  string // a person's claim id
}

type Ranking struct {
	Entries    []RankEntry
	RatedGames uint32
	// Exact is each player's fitted rating before rounding, for tests and checks.
	Exact map[string]float64
}

// Rated reports whether a finished game counts: two different rated players on two
// different teams. Two bots with the same settings are one player and tell nothing.
func Rated(r ResultRecord) bool {
	for i, a := range r.Seats {
		for _, b := range r.Seats[i+1:] {
			if a.Player != "" && b.Player != "" && a.Team != b.Team && a.Player != b.Player {
				return true
			}
		}
	}
	return false
}

type pair struct{ a, b string }

// Fit computes the Bradley-Terry maximum-likelihood ratings by Hunter's MM iteration.
// Every player also has one win and one loss against a fixed anchor of strength 1
// (rating 1500), which keeps ratings finite and pulls players with few games to 1500.
func Fit(results []ResultRecord) *Ranking {
	wins := map[pair]int64{} // wins[a,b]: a's wins over b, in weight units
	games := map[string]uint32{}
	firsts := map[string]uint32{}
	kinds := map[string]string{}
	rated := uint32(0)
	for _, r := range results {
		if !Rated(r) {
			continue
		}
		rated++
		// a person is one player per claim: name and claim id
		seats := make([]ResultSeat, len(r.Seats))
		for i, x := range r.Seats {
			if x.Kind == "person" && x.Claim != "" {
				x.Player += "\x00" + x.Claim
			}
			seats[i] = x
		}
		r.Seats = seats
		byTeam := map[uint32][]ResultSeat{}
		for _, s := range r.Seats {
			if s.Player == "" {
				continue
			}
			byTeam[s.Team] = append(byTeam[s.Team], s)
		}
		counted := map[string]bool{}
		for ta, sa := range byTeam {
			for tb, sb := range byTeam {
				if ta >= tb {
					continue
				}
				w := int64(weightUnit / (len(sa) * len(sb)))
				for _, x := range sa {
					for _, y := range sb {
						if x.Player == y.Player {
							continue // one bot setting on both teams
						}
						switch {
						case x.Place < y.Place:
							wins[pair{x.Player, y.Player}] += w
						case y.Place < x.Place:
							wins[pair{y.Player, x.Player}] += w
						default:
							wins[pair{x.Player, y.Player}] += w / 2
							wins[pair{y.Player, x.Player}] += w / 2
						}
						counted[x.Player], counted[y.Player] = true, true
					}
				}
			}
		}
		for _, s := range r.Seats {
			if counted[s.Player] {
				kinds[s.Player] = s.Kind
			}
		}
		for p := range counted {
			games[p]++
			for _, s := range r.Seats {
				if s.Player == p && s.Place == 1 {
					firsts[p]++
					break
				}
			}
		}
	}
	players := make([]string, 0, len(kinds))
	for p := range kinds {
		players = append(players, p)
	}
	sort.Strings(players)
	idx := map[string]int{}
	for i, p := range players {
		idx[p] = i
	}
	n := len(players)
	// totals in weight units: W[i] wins, N[i][j] comparisons between i and j
	W := make([]float64, n)
	N := make([][]float64, n)
	for i := range N {
		N[i] = make([]float64, n)
		W[i] = weightUnit // the anchor win
	}
	keys := make([]pair, 0, len(wins))
	for k := range wins {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].a != keys[j].a {
			return keys[i].a < keys[j].a
		}
		return keys[i].b < keys[j].b
	})
	for _, k := range keys {
		i, j := idx[k.a], idx[k.b]
		w := float64(wins[k])
		W[i] += w
		N[i][j] += w
		N[j][i] += w
	}
	gamma := make([]float64, n)
	for i := range gamma {
		gamma[i] = 1
	}
	anchorN := 2.0 * weightUnit // one win and one loss against the anchor
	next := make([]float64, n)
	for round := 0; round < fitRounds; round++ {
		worst := 0.0
		for i := 0; i < n; i++ {
			den := anchorN / (gamma[i] + 1)
			for j := 0; j < n; j++ {
				if N[i][j] != 0 {
					den += N[i][j] / (gamma[i] + gamma[j])
				}
			}
			next[i] = W[i] / den
			worst = math.Max(worst, math.Abs(next[i]-gamma[i])/gamma[i])
		}
		copy(gamma, next)
		if worst < fitTolerance {
			break
		}
	}
	out := &Ranking{RatedGames: rated, Exact: map[string]float64{}}
	for i, p := range players {
		elo := AnchorElo + 400*math.Log10(gamma[i])
		out.Exact[p] = elo
		name, claimID, _ := strings.Cut(p, "\x00")
		out.Entries = append(out.Entries, RankEntry{Player: displayPlayer(name), Kind: kinds[p], Rating: int32(math.Round(elo)), Games: games[p], Firsts: firsts[p], claim: claimID})
	}
	rankEntries(out.Entries)
	return out
}

// rankEntries orders by rating (then name) and gives equal ratings an equal rank.
func rankEntries(entries []RankEntry) {
	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if a.Rating != b.Rating {
			return a.Rating > b.Rating
		}
		return a.Player < b.Player
	})
	for i := range entries {
		entries[i].Rank = uint32(i + 1)
		if i > 0 && entries[i].Rating == entries[i-1].Rating {
			entries[i].Rank = entries[i-1].Rank
		}
	}
}

// displayPlayer shows a bot key bot:1000ms/700/margin/4 as "bot 1000 ms, explore 0.70, margin 4".
func displayPlayer(p string) string {
	if !strings.HasPrefix(p, "bot:") {
		return p
	}
	parts := strings.Split(strings.TrimPrefix(p, "bot:"), "/")
	if len(parts) < 3 {
		return p
	}
	s := "bot " + strings.TrimSuffix(parts[0], "ms") + " ms, explore " + parts[1] + ", " + parts[2]
	if len(parts) == 4 {
		s += " " + parts[3]
	}
	return s
}
