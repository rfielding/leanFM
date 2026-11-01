package goserver

// Requirement refs: grammar:play_move; property:play_move rules; game rules markdown.
// N-player Go engine. Rules (from the stakeholder's N-Player Go Lab):
//   - The board is bounded by a Wall. Cells are Wall, Open or a player colour.
//   - After placing, every adjacent group of another player with no liberty is
//     removed and counted as that owner's losses. If nothing was captured and the
//     placed group has no liberty, it is removed as suicide and counted as the
//     mover's losses. Suicide is legal.
//   - Territory is an Open region whose neighbours are one player's stones plus Wall.
//   - Score = Territory - Losses.
//   - The game ends when every player still in it has passed since the last stone,
//     when a full round of timeouts abandons it, or after 3*N*N moves.
//   - Ko (optional): simple ko plus situational superko.

import (
	"math"
	"math/rand"
	"sort"
	"time"
)

const (
	MaxPlayers  = 8
	Wall        = -1
	Open        = 0
	MovePass    = -1
	MoveResign  = -3
	MoveTimeout = -4
)

// Geom is immutable board geometry shared by every game of the same size.
type Geom struct {
	N, W, A int
	cells0  []int8
	zob     []uint64
	zt      []uint64
	pts     []int
	off     [4]int
}

var geoms = map[int]*Geom{}

func init() {
	for _, n := range AllowedBoardSizes {
		geoms[n] = makeGeom(n)
	}
}

// AllowedBoardSizes are the board sizes offered by the stakeholder's lab.
var AllowedBoardSizes = []int{5, 7, 9, 11, 13, 19}

func GeomFor(n int) *Geom { return geoms[n] }

func makeGeom(n int) *Geom {
	w := n + 2
	g := &Geom{N: n, W: w, A: w * w, off: [4]int{-1, 1, -w, w}}
	g.cells0 = make([]int8, g.A)
	for i := range g.cells0 {
		g.cells0[i] = Wall
	}
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			i := (y+1)*w + x + 1
			g.cells0[i] = Open
			g.pts = append(g.pts, i)
		}
	}
	r := rand.New(rand.NewSource(int64(0x5EED + n)))
	g.zob = make([]uint64, g.A*(MaxPlayers+1))
	for i := range g.zob {
		g.zob[i] = r.Uint64()
	}
	g.zt = make([]uint64, MaxPlayers+1)
	for i := range g.zt {
		g.zt[i] = r.Uint64()
	}
	return g
}

// Point converts a 0-based column/row to a cell index; ok is false off the board.
func (g *Geom) Point(x, y int) (int, bool) {
	if x < 0 || y < 0 || x >= g.N || y >= g.N {
		return 0, false
	}
	return (y+1)*g.W + x + 1, true
}

// XY converts a cell index back to 0-based column/row.
func (g *Geom) XY(m int) (int, int) { return m%g.W - 1, m/g.W - 1 }

// State is one game position. It is a value: Clone before mutating a shared copy.
type State struct {
	K       int
	Cells   []int8
	Losses  [MaxPlayers + 1]int
	ToMove  int
	Ko      int
	KoColor int
	KoUntil int
	MoveNo  int
	Hash    uint64
	KoOn    bool
	Out     uint32 // resigned seats
	PM      uint32 // seats that passed since the last stone
	TO      int    // consecutive timeouts
}

func NewState(g *Geom, k int, koOn bool) *State {
	c := make([]int8, g.A)
	copy(c, g.cells0)
	return &State{K: k, Cells: c, ToMove: 1, Ko: -1, KoOn: koOn}
}

func (s *State) Clone() *State {
	t := *s
	t.Cells = make([]int8, len(s.Cells))
	copy(t.Cells, s.Cells)
	return &t
}

func (g *Geom) Key(s *State) uint64 { return s.Hash ^ g.zt[s.ToMove] }

func (s *State) IsOut(p int) bool { return s.Out&(1<<uint(p)) != 0 }

func (s *State) activeCount() int {
	n := 0
	for q := 1; q <= s.K; q++ {
		if !s.IsOut(q) {
			n++
		}
	}
	return n
}

func (s *State) Abandoned() bool { return s.TO > 0 && s.TO >= s.activeCount() }

func (g *Geom) Terminal(s *State) bool {
	all := uint32(1<<uint(s.K+1)) - 2
	return (s.PM|s.Out)&all == all || s.Abandoned() || s.MoveNo >= g.N*g.N*3
}

// Work holds per-goroutine scratch space for flood fills.
type Work struct {
	g     *Geom
	mark  []int32
	lmark []int32
	stamp int32
	stack []int
	buf   []int
}

func NewWork(g *Geom) *Work {
	return &Work{g: g, mark: make([]int32, g.A), lmark: make([]int32, g.A), stack: make([]int, g.A), buf: make([]int, g.A)}
}

func (w *Work) next() int32 {
	w.stamp++
	if w.stamp == math.MaxInt32 {
		for i := range w.mark {
			w.mark[i], w.lmark[i] = 0, 0
		}
		w.stamp = 1
	}
	return w.stamp
}

func (w *Work) libsUpTo(s *State, p, limit int) int {
	c, st, off := s.Cells, w.next(), w.g.off
	col := c[p]
	sp, libs := 0, 0
	w.stack[sp] = p
	sp++
	w.mark[p] = st
	for sp > 0 {
		sp--
		q := w.stack[sp]
		for d := 0; d < 4; d++ {
			n := q + off[d]
			v := c[n]
			if v == Open {
				if w.lmark[n] != st {
					w.lmark[n] = st
					libs++
					if libs >= limit {
						return libs
					}
				}
			} else if v == col && w.mark[n] != st {
				w.mark[n] = st
				w.stack[sp] = n
				sp++
			}
		}
	}
	return libs
}

func (w *Work) removeGroup(s *State, p int) int {
	c, st, off, g := s.Cells, w.next(), w.g.off, w.g
	col := c[p]
	sp, cnt := 0, 0
	w.stack[sp] = p
	sp++
	w.mark[p] = st
	for sp > 0 {
		sp--
		q := w.stack[sp]
		c[q] = Open
		s.Hash ^= g.zob[q*(MaxPlayers+1)+int(col)]
		cnt++
		for d := 0; d < 4; d++ {
			n := q + off[d]
			if c[n] == col && w.mark[n] != st {
				w.mark[n] = st
				w.stack[sp] = n
				sp++
			}
		}
	}
	return cnt
}

// IsLegal reports whether move m is legal for the player to move, ignoring superko.
func (g *Geom) IsLegal(s *State, m int) bool {
	if m < 0 {
		return m == MovePass || m == MoveResign || m == MoveTimeout
	}
	if m >= g.A || s.Cells[m] != Open {
		return false
	}
	if s.IsOut(s.ToMove) {
		return false
	}
	if m == s.Ko && s.ToMove == s.KoColor && s.MoveNo < s.KoUntil {
		return false
	}
	return true
}

// PlayResult records what one move did.
type PlayResult struct {
	Captured int
	Suicide  int
	Victims  map[int]int
}

// Play applies m for s.ToMove. The caller checks legality first.
func (w *Work) Play(s *State, m int) PlayResult {
	g := w.g
	c := s.ToMove
	res := PlayResult{}
	if s.IsOut(c) && (m >= 0 || m == MoveTimeout) {
		m = MovePass
	}
	if m == MoveTimeout {
		s.TO++
	} else if !s.IsOut(c) {
		s.TO = 0
	}
	switch {
	case m == MoveTimeout:
		s.Ko = -1
	case m == MoveResign:
		s.Out |= 1 << uint(c)
		s.Ko = -1
	case m < 0:
		s.PM |= 1 << uint(c)
		s.Ko = -1
	default:
		s.PM = 0
		s.Cells[m] = int8(c)
		s.Hash ^= g.zob[m*(MaxPlayers+1)+c]
		capPt, victim := -1, 0
		for d := 0; d < 4; d++ {
			n := m + g.off[d]
			v := int(s.Cells[n])
			if v > 0 && v != c && w.libsUpTo(s, n, 1) == 0 {
				cnt := w.removeGroup(s, n)
				s.Losses[v] += cnt
				res.Captured += cnt
				capPt, victim = n, v
				if res.Victims == nil {
					res.Victims = map[int]int{}
				}
				res.Victims[v] += cnt
			}
		}
		if res.Captured == 0 {
			if w.libsUpTo(s, m, 1) == 0 {
				res.Suicide = w.removeGroup(s, m)
				s.Losses[c] += res.Suicide
			}
			s.Ko = -1
		} else {
			solo := true
			for d := 0; d < 4; d++ {
				if int(s.Cells[m+g.off[d]]) == c {
					solo = false
				}
			}
			if s.KoOn && res.Captured == 1 && solo && w.libsUpTo(s, m, 2) == 1 {
				s.Ko, s.KoColor, s.KoUntil = capPt, victim, s.MoveNo+s.K
			} else {
				s.Ko = -1
			}
		}
	}
	s.MoveNo++
	s.ToMove = s.ToMove%s.K + 1
	return res
}

// Score is territory, losses and Territory - Losses for every seat.
type Score struct {
	Territory [MaxPlayers + 1]int
	Scores    [MaxPlayers + 1]int
	Owner     []int8 // per cell: owning player of an empty region, else 0
}

func (w *Work) Score(s *State, wantOwner bool) Score {
	var out Score
	c, st, off := s.Cells, w.next(), w.g.off
	if wantOwner {
		out.Owner = make([]int8, w.g.A)
	}
	for _, q0 := range w.g.pts {
		if c[q0] != Open || w.mark[q0] == st {
			continue
		}
		sp, size := 0, 0
		var mask uint32
		w.stack[sp] = q0
		sp++
		w.mark[q0] = st
		region := w.buf[:0]
		for sp > 0 {
			sp--
			q := w.stack[sp]
			size++
			if wantOwner {
				region = append(region, q)
			}
			for d := 0; d < 4; d++ {
				n := q + off[d]
				v := c[n]
				if v == Open {
					if w.mark[n] != st {
						w.mark[n] = st
						w.stack[sp] = n
						sp++
					}
				} else if v > 0 {
					mask |= 1 << uint(v)
				}
			}
		}
		if mask != 0 && mask&(mask-1) == 0 {
			o := 0
			for mask>>uint(o+1) != 0 {
				o++
			}
			out.Territory[o] += size
			for _, r := range region {
				out.Owner[r] = int8(o)
			}
		}
	}
	for i := 1; i <= s.K; i++ {
		out.Scores[i] = out.Territory[i] - s.Losses[i]
	}
	return out
}

func (w *Work) isOwnEye(s *State, p, c int) bool {
	for d := 0; d < 4; d++ {
		v := int(s.Cells[p+w.g.off[d]])
		if v != c && v != Wall {
			return false
		}
	}
	return true
}

func (w *Work) inOwnRegion(s *State, p, c int) bool {
	cl, st, off := s.Cells, w.next(), w.g.off
	sp, own := 0, false
	w.stack[sp] = p
	sp++
	w.mark[p] = st
	for sp > 0 {
		sp--
		q := w.stack[sp]
		for d := 0; d < 4; d++ {
			n := q + off[d]
			v := int(cl[n])
			if v == Open {
				if w.mark[n] != st {
					w.mark[n] = st
					w.stack[sp] = n
					sp++
				}
			} else if v > 0 {
				if v != c {
					return false
				}
				own = true
			}
		}
	}
	return own
}

func (w *Work) wouldSuicide(s *State, p, c int) bool {
	for d := 0; d < 4; d++ {
		n := p + w.g.off[d]
		v := int(s.Cells[n])
		if v == Open {
			return false
		}
		if v == c {
			if w.libsUpTo(s, n, 2) >= 2 {
				return false
			}
		} else if v > 0 {
			if w.libsUpTo(s, n, 2) == 1 {
				return false
			}
		}
	}
	return true
}

func (w *Work) genMoves(s *State) []int {
	out := []int{MovePass}
	if s.IsOut(s.ToMove) {
		return out
	}
	for _, p := range w.g.pts {
		if w.g.IsLegal(s, p) {
			out = append(out, p)
		}
	}
	return out
}

func (w *Work) playoutMove(s *State, rng *rand.Rand) int {
	c := s.ToMove
	if s.IsOut(c) {
		return MovePass
	}
	n := 0
	sc := w.buf
	for _, p := range w.g.pts {
		if s.Cells[p] == Open {
			sc[n] = p
			n++
		}
	}
	for n > 0 {
		j := rng.Intn(n)
		m := sc[j]
		n--
		sc[j] = sc[n]
		if w.g.IsLegal(s, m) && !w.isOwnEye(s, m, c) && !w.wouldSuicide(s, m, c) && !w.inOwnRegion(s, m, c) {
			return m
		}
	}
	return MovePass
}

// rewards: soft margin of each player against its best rival.
func rewards(sc [MaxPlayers + 1]int, k int, T float64) [MaxPlayers + 1]float64 {
	var r [MaxPlayers + 1]float64
	for i := 1; i <= k; i++ {
		best := math.Inf(-1)
		for j := 1; j <= k; j++ {
			if j != i && float64(sc[j]) > best {
				best = float64(sc[j])
			}
		}
		r[i] = 1 / (1 + math.Exp(-(float64(sc[i])-best)/T))
	}
	return r
}

// cleanupMove: before passing, capture an enemy group sealed inside the mover's
// area when filling its liberties gains at least one point of margin and costs
// no own stones. Returns the first liberty to play or -1.
func (w *Work) cleanupMove(s *State, c int, teams []int) int {
	g := w.g
	cl := s.Cells
	tm := func(q int) int {
		if teams != nil {
			return teams[q-1]
		}
		return q
	}
	margin := func(sc [MaxPlayers + 1]int) int {
		tot := map[int]int{}
		for q := 1; q <= s.K; q++ {
			tot[tm(q)] += sc[q]
		}
		me, rival, any := tot[tm(c)], math.MinInt32, false
		for t, v := range tot {
			if t != tm(c) && v > rival {
				rival, any = v, true
			}
		}
		if !any {
			return me
		}
		return me - rival
	}
	base := margin(w.Score(s, false).Scores)
	done := make([]bool, g.A)
	best, bestGain := -1, 0
	for _, p := range g.pts {
		v := int(cl[p])
		if v <= 0 || v == c || done[p] || (teams != nil && tm(v) == tm(c)) {
			continue
		}
		grp, libs := []int{}, []int{}
		seenL := map[int]bool{}
		stk := []int{p}
		sealed := true
		done[p] = true
		for len(stk) > 0 {
			q := stk[len(stk)-1]
			stk = stk[:len(stk)-1]
			grp = append(grp, q)
			for d := 0; d < 4; d++ {
				n := q + g.off[d]
				x := int(cl[n])
				if x == v && !done[n] {
					done[n] = true
					stk = append(stk, n)
				} else if x == Open && !seenL[n] {
					seenL[n] = true
					libs = append(libs, n)
				} else if x > 0 && x != v && x != c {
					sealed = false
				}
			}
		}
		if !sealed || len(libs) > 4 {
			continue
		}
		for _, l := range libs {
			if !sealed {
				break
			}
			vis := map[int]bool{l: true}
			stk2 := []int{l}
			for len(stk2) > 0 && sealed {
				r := stk2[len(stk2)-1]
				stk2 = stk2[:len(stk2)-1]
				for d := 0; d < 4; d++ {
					n2 := r + g.off[d]
					x := int(cl[n2])
					if x == Open && !vis[n2] {
						vis[n2] = true
						stk2 = append(stk2, n2)
					} else if x > 0 && x != c && x != v {
						sealed = false
					}
				}
			}
		}
		if !sealed {
			continue
		}
		s2 := s.Clone()
		ok, first := true, -1
		for _, l := range libs {
			if s2.Cells[l] != Open {
				continue
			}
			s2.ToMove, s2.PM = c, 0
			if !g.IsLegal(s2, l) {
				ok = false
				break
			}
			t := s2.Clone()
			t.ToMove = c
			w.Play(t, l)
			if t.Losses[c] != s.Losses[c] {
				ok = false
				break
			}
			if first < 0 {
				if t.Cells[grp[0]] != Open && w.libsUpTo(t, l, 2) < 2 {
					continue
				}
				first = l
			}
			s2 = t
		}
		if !ok || first < 0 || s2.Cells[grp[0]] != Open {
			continue
		}
		gain := margin(w.Score(s2, false).Scores) - base
		if gain > bestGain {
			bestGain, best = gain, first
		}
	}
	return best
}

// SearchParams bounds one bot search.
type SearchParams struct {
	Budget  time.Duration
	C       float64 // UCT exploration constant (Lab default 0.7)
	T       float64 // margin softness in points (Lab default 4)
	Mode    string  // "margin" (default), "win" or "rank"
	Teams   []int   // per seat (index 0 = seat 1) team number; nil = everyone alone
	NodeCap int
	Seed    int64
	History map[uint64]bool // earlier position keys, used when ko is on (advisory)
}

// Candidate is one root child of a search, in the Lab's terms.
type Candidate struct {
	Move    int
	Visits  int
	Reward  float64                 // mover's mean reward through this move
	Outlook [MaxPlayers + 1]float64 // every seat's mean reward through this move
	Proj    [MaxPlayers + 1]float64 // every seat's mean final score through this move
}

// SearchResult is the bot's chosen move and its evidence.
type SearchResult struct {
	Move       int
	Iterations int
	Elapsed    time.Duration
	Guard      bool
	Top        []Candidate             // at most 8, most visited first
	RootQ      [MaxPlayers + 1]float64 // mean reward per seat at the root
	RootProj   [MaxPlayers + 1]float64 // mean final score per seat at the root
}

type node struct {
	move     int
	parent   *node
	children []*node
	untried  []int
	expanded bool
	n        int
	w        [MaxPlayers + 1]float64
	sc       [MaxPlayers + 1]float64 // summed final scores (root children only)
	key      uint64
}

// pickMove chooses among the well-visited root children whose mean reward is
// within 0.02 of the most visited one, the move with the highest projected final
// score for the mover's team, preferring a pass on ties. The soft-margin reward
// saturates near 1 when a seat is far ahead, which otherwise makes filling its
// own territory look as good as passing; projected score still tells them apart.
func pickMove(kids []*node, mover, k int, teams []int) int {
	best := kids[0]
	bestR := best.w[mover] / float64(best.n)
	proj := func(ch *node) float64 {
		v := 0.0
		for b := 1; b <= k; b++ {
			if b == mover || (teams != nil && teams[b-1] == teams[mover-1]) {
				v += ch.sc[b] / float64(ch.n)
			}
		}
		return v
	}
	choice, choiceP := best, proj(best)
	for _, ch := range kids[1:] {
		if ch.n*2 < best.n || math.Abs(ch.w[mover]/float64(ch.n)-bestR) > 0.02 {
			continue
		}
		pv := proj(ch)
		if pv > choiceP+1e-9 || (math.Abs(pv-choiceP) <= 1e-9 && ch.move == MovePass) {
			choice, choiceP = ch, pv
		}
	}
	return choice.move
}

// Rewards maps final seat scores to a reward per seat in [0,1], as in the Lab:
// margin = logistic of (own - best rival)/T, win = 1/#winners, rank = 1 - (above + ties/2)/(k-1).
// With teams, allies share one reward computed from team totals.
func Rewards(sc [MaxPlayers + 1]int, k int, mode string, T float64, teams []int) [MaxPlayers + 1]float64 {
	var r [MaxPlayers + 1]float64
	if teams != nil {
		ids := []int{}
		tot := map[int]int{}
		for i := 1; i <= k; i++ {
			t := teams[i-1]
			if _, ok := tot[t]; !ok {
				ids = append(ids, t)
			}
			tot[t] += sc[i]
		}
		if len(ids) == 1 {
			v := 1 / (1 + math.Exp(-float64(tot[ids[0]])/T))
			for i := 1; i <= k; i++ {
				r[i] = v
			}
			return r
		}
		var tsc [MaxPlayers + 1]int
		for j, t := range ids {
			tsc[j+1] = tot[t]
		}
		tr := Rewards(tsc, len(ids), mode, T, nil)
		for i := 1; i <= k; i++ {
			for j, t := range ids {
				if t == teams[i-1] {
					r[i] = tr[j+1]
				}
			}
		}
		return r
	}
	switch mode {
	case "win":
		mx, n := math.MinInt32, 0
		for i := 1; i <= k; i++ {
			if sc[i] > mx {
				mx = sc[i]
			}
		}
		for i := 1; i <= k; i++ {
			if sc[i] == mx {
				n++
			}
		}
		for i := 1; i <= k; i++ {
			if sc[i] == mx {
				r[i] = 1 / float64(n)
			}
		}
	case "rank":
		for i := 1; i <= k; i++ {
			above, eq := 0, 0
			for j := 1; j <= k; j++ {
				if sc[j] > sc[i] {
					above++
				} else if j != i && sc[j] == sc[i] {
					eq++
				}
			}
			if k > 1 {
				r[i] = 1 - (float64(above)+float64(eq)/2)/float64(k-1)
			} else {
				r[i] = 1
			}
		}
	default:
		r = rewards(sc, k, T)
	}
	return r
}

// Search runs max^n UCT from root and returns the most visited move with the
// Lab's summary. It never mutates root and stops at the time budget or node cap.
func Search(g *Geom, root *State, p SearchParams) SearchResult {
	start := time.Now()
	w := NewWork(g)
	rng := rand.New(rand.NewSource(p.Seed))
	if p.C == 0 {
		p.C = 0.7
	}
	if p.T == 0 {
		p.T = 4
	}
	if p.NodeCap == 0 {
		p.NodeCap = 200000
	}
	k := root.K
	if root.IsOut(root.ToMove) {
		return SearchResult{Move: MovePass}
	}
	R := &node{move: -2, key: g.Key(root), untried: w.genMoves(root), expanded: true}
	repeats := func(key uint64, nd *node) bool {
		if p.History[key] {
			return true
		}
		for q := nd; q != nil; q = q.parent {
			if q.key == key {
				return true
			}
		}
		return false
	}
	var rootScore [MaxPlayers + 1]float64
	nodes, iters := 1, 0
	deadline := start.Add(p.Budget)
	for {
		for b := 0; b < 16; b++ {
			s := root.Clone()
			nd := R
			path := []*node{R}
			for nd.expanded && len(nd.untried) == 0 && len(nd.children) > 0 {
				pl := s.ToMove
				lnN := math.Log(float64(nd.n))
				var best *node
				bv := math.Inf(-1)
				for _, ch := range nd.children {
					v := ch.w[pl]/float64(ch.n) + p.C*math.Sqrt(lnN/float64(ch.n))
					if v > bv {
						bv, best = v, ch
					}
				}
				nd = best
				w.Play(s, nd.move)
				path = append(path, nd)
			}
			if !g.Terminal(s) {
				if !nd.expanded && nodes < p.NodeCap {
					nd.untried = w.genMoves(s)
					nd.expanded = true
				}
				for nodes < p.NodeCap && len(nd.untried) > 0 {
					u := nd.untried
					j := rng.Intn(len(u))
					m := u[j]
					u[j] = u[len(u)-1]
					nd.untried = u[:len(u)-1]
					s2 := s.Clone()
					w.Play(s2, m)
					key := g.Key(s2)
					if m >= 0 && root.KoOn && repeats(key, nd) {
						continue
					}
					c2 := &node{move: m, parent: nd, key: key}
					if g.Terminal(s2) {
						c2.expanded = true
					}
					nd.children = append(nd.children, c2)
					nodes++
					nd, s = c2, s2
					path = append(path, c2)
					break
				}
			}
			for !g.Terminal(s) {
				w.Play(s, w.playoutMove(s, rng))
			}
			final := w.Score(s, false).Scores
			rw := Rewards(final, k, p.Mode, p.T, p.Teams)
			for _, x := range path {
				x.n++
				for b := 1; b <= k; b++ {
					x.w[b] += rw[b]
				}
			}
			for b := 1; b <= k; b++ {
				rootScore[b] += float64(final[b])
				if len(path) > 1 {
					path[1].sc[b] += float64(final[b])
				}
			}
			iters++
		}
		if time.Now().After(deadline) {
			break
		}
	}
	mover := root.ToMove
	kids := append([]*node{}, R.children...)
	sort.SliceStable(kids, func(a, b int) bool {
		if kids[a].n != kids[b].n {
			return kids[a].n > kids[b].n
		}
		return kids[a].w[mover] > kids[b].w[mover]
	})
	res := SearchResult{Move: MovePass, Iterations: iters}
	for i, ch := range kids {
		if i == 8 || ch.n == 0 {
			break
		}
		c := Candidate{Move: ch.move, Visits: ch.n, Reward: ch.w[mover] / float64(ch.n)}
		for b := 1; b <= k; b++ {
			c.Outlook[b] = ch.w[b] / float64(ch.n)
			c.Proj[b] = ch.sc[b] / float64(ch.n)
		}
		res.Top = append(res.Top, c)
	}
	if R.n > 0 {
		for b := 1; b <= k; b++ {
			res.RootQ[b] = R.w[b] / float64(R.n)
			res.RootProj[b] = rootScore[b] / float64(R.n)
		}
	}
	if len(kids) > 0 {
		res.Move = pickMove(kids, mover, k, p.Teams)
	}
	if res.Move == MovePass {
		if cm := w.cleanupMove(root, mover, p.Teams); cm >= 0 {
			res.Move, res.Guard = cm, true
		}
	}
	res.Elapsed = time.Since(start)
	return res
}
