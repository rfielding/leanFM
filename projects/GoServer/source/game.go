package goserver

// Requirement refs: grammar:create_game, grammar:set_seat_plan, grammar:take_seat,
// grammar:leave_seat, grammar:start_game, grammar:set_autopilot, grammar:play_move,
// grammar:propose_merge, grammar:respond_merge, grammar:game_state, task:turn,
// task:bot_turn, task:team_merge, task:game_lifecycle and their never-proofs.

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

const (
	GameOpen     = "open"
	GamePlaying  = "playing"
	GameFinished = "finished"

	KoAuto = 0 // on for two players, off for three or more
	KoOff  = 1
	KoOn   = 2 // simple ko plus situational superko

	CtlOpen      = "open"
	CtlBot       = "bot"
	CtlPerson    = "person"
	CtlAutopilot = "autopilot" // view only: a person's seat played by a bot

	DefaultBoardSize      = 11
	DefaultSeats          = 4
	DefaultTurnDeadlineMS = 10000
	DefaultBotMS          = 1000
	DefaultExploreMilli   = 700
	DefaultRewardMode     = "margin"
	DefaultSoftness       = 4
	MinTurnDeadlineMS     = 5000
	MaxTurnDeadlineMS     = 3840000
	MinBotMS              = 250
	MaxBotMS              = 16000
	MaxMoveRecords        = 3 * 19 * 19
)

var allowedExplore = map[uint32]bool{500: true, 700: true, 1000: true, 1400: true}
var allowedRewardModes = map[string]bool{"margin": true, "win": true, "rank": true}
var allowedSoftness = map[uint32]bool{2: true, 4: true, 8: true}

// ---------- wire messages (JSON camelCase mapping of spec/Requirements.proto) ----------

type SeatPlan struct {
	Seat       uint32 `json:"seat"`
	Controller string `json:"controller"` // "bot" or "open"
	Team       uint32 `json:"team"`
}
type SetSeatPlan struct {
	SessionID  string `json:"sessionId"`
	GameID     string `json:"gameId"`
	Seat       uint32 `json:"seat"`
	Controller string `json:"controller"`
	Team       uint32 `json:"team"`
	RequestID  uint64 `json:"requestId"`
}
type SeatPlanSet struct {
	GameID     string `json:"gameId"`
	Seat       uint32 `json:"seat"`
	Controller string `json:"controller"`
	Team       uint32 `json:"team"`
	RequestID  uint64 `json:"requestId"`
}
type TakeSeat struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	Seat      uint32 `json:"seat"` // 1-based; 0 means first open seat
	RequestID uint64 `json:"requestId"`
}
type SeatTaken struct {
	GameID    string `json:"gameId"`
	Seat      uint32 `json:"seat"`
	RequestID uint64 `json:"requestId"`
}
type LeaveSeat struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	RequestID uint64 `json:"requestId"`
}
type SeatLeft struct {
	GameID    string `json:"gameId"`
	Seat      uint32 `json:"seat"`
	RequestID uint64 `json:"requestId"`
}
type StartGame struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	RequestID uint64 `json:"requestId"`
}
type GameStarted struct {
	GameID    string     `json:"gameId"`
	Seats     []SeatView `json:"seats"`
	RequestID uint64     `json:"requestId"`
}
type SetAutopilot struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	On        bool   `json:"on"`
	RequestID uint64 `json:"requestId"`
}
type AutopilotSet struct {
	GameID    string `json:"gameId"`
	Seat      uint32 `json:"seat"`
	On        bool   `json:"on"`
	RequestID uint64 `json:"requestId"`
}
type PlayMove struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	MoveNo    uint32 `json:"moveNo"` // must equal the current move number
	Kind      string `json:"kind"`   // "place", "pass" or "resign"
	X         uint32 `json:"x"`
	Y         uint32 `json:"y"`
	RequestID uint64 `json:"requestId"`
}
type MovePlayed struct {
	GameID    string   `json:"gameId"`
	MoveNo    uint32   `json:"moveNo"`
	Seat      uint32   `json:"seat"`
	Kind      string   `json:"kind"`
	X         uint32   `json:"x"`
	Y         uint32   `json:"y"`
	Captured  uint32   `json:"captured"`
	RequestID uint64   `json:"requestId"`
	Victims   []uint32 `json:"victims"`
	Suicide   uint32   `json:"suicide"`
}
type ProposeMerge struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	OtherTeam uint32 `json:"otherTeam"`
	RequestID uint64 `json:"requestId"`
}
type MergeProposed struct {
	GameID     string `json:"gameId"`
	ProposalID uint32 `json:"proposalId"`
	TeamA      uint32 `json:"teamA"`
	TeamB      uint32 `json:"teamB"`
	RequestID  uint64 `json:"requestId"`
}
type RespondMerge struct {
	SessionID  string `json:"sessionId"`
	GameID     string `json:"gameId"`
	ProposalID uint32 `json:"proposalId"`
	Accept     bool   `json:"accept"`
	RequestID  uint64 `json:"requestId"`
}
type MergeResponded struct {
	GameID     string `json:"gameId"`
	ProposalID uint32 `json:"proposalId"`
	Status     string `json:"status"` // pending, merged or withdrawn
	RequestID  uint64 `json:"requestId"`
}
type GetGameState struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	SinceMove uint32 `json:"sinceMove"`
	RequestID uint64 `json:"requestId"`
}
type SeatView struct {
	Seat       uint32   `json:"seat"`
	Player     string   `json:"player"`
	Controller string   `json:"controller"`
	Team       uint32   `json:"team"`
	Territory  int32    `json:"territory"`
	Losses     int32    `json:"losses"`
	Score      int32    `json:"score"`
	Resigned   bool     `json:"resigned"`
	LossesBy   []uint32 `json:"lossesBy"` // index i: own stones removed by seat i+1 (own index = suicide)
}
type TeamView struct {
	Team      uint32   `json:"team"`
	Seats     []uint32 `json:"seats"`
	Territory int32    `json:"territory"`
	Losses    int32    `json:"losses"`
	Score     int32    `json:"score"`
}
type MergeView struct {
	ProposalID uint32   `json:"proposalId"`
	TeamA      uint32   `json:"teamA"`
	TeamB      uint32   `json:"teamB"`
	Proposer   string   `json:"proposer"`
	AcceptedBy []string `json:"acceptedBy"`
	WaitingFor []string `json:"waitingFor"`
}
type CandidateView struct {
	Kind            string  `json:"kind"`
	X               uint32  `json:"x"`
	Y               uint32  `json:"y"`
	Visits          uint32  `json:"visits"`
	RewardPermille  int32   `json:"rewardPermille"`
	OutlookPermille []int32 `json:"outlookPermille"`
	ProjMilli       []int32 `json:"projMilli"`
}
type SearchSummary struct {
	Playouts            uint32          `json:"playouts"`
	Ms                  uint32          `json:"ms"`
	Candidates          []CandidateView `json:"candidates"`
	RootProjMilli       []int32         `json:"rootProjMilli"`
	RootOutlookPermille []int32         `json:"rootOutlookPermille"`
	Guard               bool            `json:"guard"`
}
type MoveRecord struct {
	MoveNo   uint32         `json:"moveNo"`
	Seat     uint32         `json:"seat"`
	Kind     string         `json:"kind"` // place, pass, resign, timeout
	X        uint32         `json:"x"`
	Y        uint32         `json:"y"`
	Captured uint32         `json:"captured"`
	Source   string         `json:"source"` // person, bot, autopilot, deadline, resigned
	Victims  []uint32       `json:"victims"`
	Suicide  uint32         `json:"suicide"`
	Search   *SearchSummary `json:"search"`
}
type GameState struct {
	GameID         string       `json:"gameId"`
	GameName       string       `json:"gameName"`
	Status         string       `json:"status"`
	Creator        string       `json:"creator"`
	BoardSize      uint32       `json:"boardSize"`
	KoOn           bool         `json:"koOn"`
	TurnDeadlineMS uint64       `json:"turnDeadlineMs"`
	BotMS          uint64       `json:"botMs"`
	MoveNo         uint32       `json:"moveNo"`
	ToMove         uint32       `json:"toMove"`
	RemainingMS    uint64       `json:"remainingMs"`
	Cells          []int32      `json:"cells"`
	Owner          []int32      `json:"owner"`
	Seats          []SeatView   `json:"seats"`
	Teams          []TeamView   `json:"teams"`
	Proposals      []MergeView  `json:"proposals"`
	Moves          []MoveRecord `json:"moves"`
	Winners        []uint32     `json:"winners"`
	EndReason      string       `json:"endReason"`
	ExploreMilli   uint32       `json:"exploreMilli"`
	RewardMode     string       `json:"rewardMode"`
	Softness       uint32       `json:"softness"`
	RequestID      uint64       `json:"requestId"`
}

// ---------- authoritative game state ----------

type seat struct {
	player     string // person identity or bot-<n>; empty while open
	controller string // CtlOpen, CtlBot or CtlPerson
	autopilot  bool   // a person's seat currently played by a bot
	team       int
}

func (st *seat) botControlled() bool { return st.controller == CtlBot || st.autopilot }

func (st *seat) viewController() string {
	if st.controller == CtlPerson && st.autopilot {
		return CtlAutopilot
	}
	return st.controller
}

type proposal struct {
	id       uint32
	a, b     int
	proposer string
	accepted map[string]bool
}

type play struct {
	geom      *Geom
	state     *State
	history   map[uint64][][]byte // situational keys backed by exact positions
	moves     []MoveRecord
	bowl      [MaxPlayers + 1][MaxPlayers + 1]int // bowl[victim][capturer]
	turnSeq   uint64
	turnBegan time.Time // start of the current turn; never reset by autopilot switches
	botStart  time.Time // start of the current bot search, when a bot controls the turn
	timer     *time.Timer
	endReason string
}

func normalizeGameParams(r CreateGame) (cfg gameConfig, code string) {
	cfg.board = int(r.BoardSize)
	if cfg.board == 0 {
		cfg.board = DefaultBoardSize
	}
	if GeomFor(cfg.board) == nil {
		return cfg, "invalid_board"
	}
	cfg.seats = int(r.Seats)
	if cfg.seats == 0 {
		cfg.seats = DefaultSeats
	}
	if cfg.seats < 2 || cfg.seats > MaxPlayers {
		return cfg, "invalid_seats"
	}
	cfg.deadline = r.TurnDeadlineMS
	if cfg.deadline == 0 {
		cfg.deadline = DefaultTurnDeadlineMS
	}
	if cfg.deadline < MinTurnDeadlineMS || cfg.deadline > MaxTurnDeadlineMS {
		return cfg, "invalid_deadline"
	}
	cfg.bot = r.BotMS
	if cfg.bot == 0 {
		cfg.bot = DefaultBotMS
	}
	if cfg.bot < MinBotMS || cfg.bot > MaxBotMS {
		return cfg, "invalid_bot_time"
	}
	cfg.ko = int(r.KoRule)
	if cfg.ko < KoAuto || cfg.ko > KoOn {
		return cfg, "invalid_ko_rule"
	}
	cfg.explore = r.ExploreMilli
	if cfg.explore == 0 {
		cfg.explore = DefaultExploreMilli
	}
	if !allowedExplore[cfg.explore] {
		return cfg, "invalid_bot_settings"
	}
	cfg.mode = r.RewardMode
	if cfg.mode == "" {
		cfg.mode = DefaultRewardMode
	}
	if !allowedRewardModes[cfg.mode] {
		return cfg, "invalid_bot_settings"
	}
	cfg.softness = r.Softness
	if cfg.softness == 0 {
		cfg.softness = DefaultSoftness
	}
	if !allowedSoftness[cfg.softness] {
		return cfg, "invalid_bot_settings"
	}
	cfg.plan = make([]seat, cfg.seats)
	for i := range cfg.plan {
		cfg.plan[i] = seat{controller: CtlOpen, team: i + 1}
	}
	seen := map[uint32]bool{}
	for _, p := range r.SeatPlan {
		if p.Seat < 1 || int(p.Seat) > cfg.seats || seen[p.Seat] {
			return cfg, "invalid_seat_plan"
		}
		seen[p.Seat] = true
		st := &cfg.plan[p.Seat-1]
		switch p.Controller {
		case "", CtlOpen:
			st.controller = CtlOpen
		case CtlBot:
			st.controller = CtlBot
		default:
			return cfg, "invalid_seat_plan"
		}
		if p.Team != 0 {
			if int(p.Team) > cfg.seats {
				return cfg, "invalid_seat_plan"
			}
			st.team = int(p.Team)
		}
	}
	return cfg, ""
}

type gameConfig struct {
	board, seats, ko int
	deadline, bot    uint64
	explore          uint32
	mode             string
	softness         uint32
	plan             []seat
}

func (s *ServerCore) humanLimit(g *game) time.Duration {
	if s.turnLimit > 0 {
		return s.turnLimit
	}
	return time.Duration(g.turnDeadlineMs) * time.Millisecond
}

func (s *ServerCore) botBudget(g *game) time.Duration {
	if s.botBudgetOverride > 0 {
		return s.botBudgetOverride
	}
	return time.Duration(g.botMs) * time.Millisecond
}

func koEnabled(rule, seats int) bool {
	switch rule {
	case KoOff:
		return false
	case KoOn:
		return true
	}
	return seats <= 2
}

func botName(seat int) string { return fmt.Sprintf("bot-%d", seat) }

// seatOf returns the 1-based seat a person holds, or 0.
func (g *game) seatOf(identity string) int {
	for i, st := range g.seatInfo {
		if st.controller == CtlPerson && st.player == identity {
			return i + 1
		}
	}
	return 0
}

// Requirement refs: grammar:set_seat_plan; proof:set_seat_plan never crosses authority.
func (s *ServerCore) setSeatPlan(r SetSeatPlan) any {
	return s.cached(r.SessionID, "set_seat_plan", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "set_seat_plan")
		}
		if g.creator != identity {
			return reject(r.RequestID, "not_creator", "set_seat_plan")
		}
		if g.status != GameOpen {
			return reject(r.RequestID, "not_open", "set_seat_plan")
		}
		if r.Seat < 1 || int(r.Seat) > g.seats || (r.Controller != CtlBot && r.Controller != CtlOpen) || r.Team < 1 || int(r.Team) > g.seats {
			return reject(r.RequestID, "invalid_seat_plan", "set_seat_plan")
		}
		st := &g.seatInfo[r.Seat-1]
		if st.controller == CtlPerson && r.Controller == CtlBot {
			return reject(r.RequestID, "seat_occupied", "set_seat_plan")
		}
		if st.controller != CtlPerson {
			st.controller = r.Controller
		}
		st.team = int(r.Team)
		return SeatPlanSet{GameID: g.id, Seat: r.Seat, Controller: r.Controller, Team: r.Team, RequestID: r.RequestID}
	})
}

// Requirement refs: grammar:take_seat; proof:take_seat never crosses authority or scope.
func (s *ServerCore) takeSeat(r TakeSeat) any {
	return s.cached(r.SessionID, "take_seat", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, rm := s.findGame(r.GameID)
		if g == nil || rm == nil || !rm.members[identity] || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "take_seat")
		}
		if g.status != GameOpen {
			return reject(r.RequestID, "not_open", "take_seat")
		}
		if have := g.seatOf(identity); have > 0 {
			return reject(r.RequestID, "already_seated", "take_seat").withScope(fmt.Sprint(have))
		}
		n := int(r.Seat)
		if n == 0 {
			for i, st := range g.seatInfo {
				if st.controller == CtlOpen {
					n = i + 1
					break
				}
			}
		}
		if n < 1 || n > g.seats || g.seatInfo[n-1].controller != CtlOpen {
			return reject(r.RequestID, "seat_unavailable", "take_seat")
		}
		g.seatInfo[n-1].controller = CtlPerson
		g.seatInfo[n-1].player = identity
		return SeatTaken{GameID: g.id, Seat: uint32(n), RequestID: r.RequestID}
	})
}

// Requirement refs: grammar:leave_seat; proof:leave_seat never crosses authority.
func (s *ServerCore) leaveSeat(r LeaveSeat) any {
	return s.cached(r.SessionID, "leave_seat", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "leave_seat")
		}
		if g.status != GameOpen {
			return reject(r.RequestID, "not_open", "leave_seat")
		}
		n := g.seatOf(identity)
		if n == 0 {
			return reject(r.RequestID, "not_seated", "leave_seat")
		}
		g.seatInfo[n-1].controller = CtlOpen
		g.seatInfo[n-1].player = ""
		return SeatLeft{GameID: g.id, Seat: uint32(n), RequestID: r.RequestID}
	})
}

// Requirement refs: grammar:start_game; proof:start_game never crosses authority or scope.
func (s *ServerCore) startGame(r StartGame) any {
	return s.cached(r.SessionID, "start_game", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, rm := s.findGame(r.GameID)
		if g == nil || rm == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "start_game")
		}
		if g.creator != identity {
			return reject(r.RequestID, "not_creator", "start_game")
		}
		if g.status != GameOpen {
			return reject(r.RequestID, "not_open", "start_game")
		}
		for i := range g.seatInfo {
			if g.seatInfo[i].controller != CtlPerson {
				g.seatInfo[i] = seat{player: botName(i + 1), controller: CtlBot, team: g.seatInfo[i].team}
			}
		}
		geom := GeomFor(g.boardSize)
		st := NewState(geom, g.seats, koEnabled(g.koRule, g.seats))
		g.play = &play{geom: geom, state: st, history: map[uint64][][]byte{}}
		g.play.remember(st)
		g.status = GamePlaying
		s.beginTurnLocked(g)
		return GameStarted{GameID: g.id, Seats: s.seatViewsLocked(g, nil), RequestID: r.RequestID}
	})
}

// Requirement refs: grammar:set_autopilot; property:set_autopilot keeps the seat;
// proof:set_autopilot never crosses authority.
func (s *ServerCore) setAutopilot(r SetAutopilot) any {
	return s.cached(r.SessionID, "set_autopilot", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "set_autopilot")
		}
		if g.status != GamePlaying {
			return reject(r.RequestID, "not_playing", "set_autopilot")
		}
		n := g.seatOf(identity)
		if n == 0 {
			return reject(r.RequestID, "not_seated", "set_autopilot")
		}
		st := &g.seatInfo[n-1]
		if st.autopilot != r.On {
			st.autopilot = r.On
			p := g.play
			if p.state.ToMove == n && !p.state.IsOut(n) {
				// The switch takes effect on the current turn: discard any pending
				// bot result and restart the controller's clock; the person's
				// deadline is always measured from the start of the turn.
				p.turnSeq++
				if p.timer != nil {
					p.timer.Stop()
					p.timer = nil
				}
				s.armTurnLocked(g, false)
			}
		}
		return AutopilotSet{GameID: g.id, Seat: uint32(n), On: r.On, RequestID: r.RequestID}
	})
}

// Requirement refs: grammar:play_move; property:play_move rules; proof:play_move never crosses authority or scope.
func (s *ServerCore) playMove(r PlayMove) any {
	return s.cached(r.SessionID, "play_move", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "play_move")
		}
		if g.status != GamePlaying || g.play == nil {
			return reject(r.RequestID, "not_playing", "play_move")
		}
		p := g.play
		st := p.state
		n := st.ToMove
		seatNow := &g.seatInfo[n-1]
		if seatNow.controller != CtlPerson || seatNow.player != identity || seatNow.autopilot {
			return reject(r.RequestID, "not_your_turn", "play_move")
		}
		if int(r.MoveNo) != st.MoveNo {
			return reject(r.RequestID, "stale_move", "play_move")
		}
		if s.clock().Sub(p.turnBegan) > s.humanLimit(g) {
			// The deadline has passed but its timer has not fired yet: the timeout wins.
			s.applyLocked(g, MoveTimeout, "deadline", nil)
			return reject(r.RequestID, "deadline_passed", "play_move")
		}
		var m int
		switch r.Kind {
		case "pass":
			m = MovePass
		case "resign":
			m = MoveResign
		case "place":
			pt, ok := p.geom.Point(int(r.X), int(r.Y))
			if !ok {
				return reject(r.RequestID, "illegal_move", "play_move")
			}
			m = pt
		default:
			return reject(r.RequestID, "illegal_move", "play_move")
		}
		if code := s.legalLocked(p, m); code != "" {
			return reject(r.RequestID, code, "play_move")
		}
		rec := s.applyLocked(g, m, "person", nil)
		return MovePlayed{GameID: g.id, MoveNo: rec.MoveNo, Seat: rec.Seat, Kind: rec.Kind, X: rec.X, Y: rec.Y, Captured: rec.Captured, Victims: rec.Victims, Suicide: rec.Suicide, RequestID: r.RequestID}
	})
}

// legalLocked checks rules plus situational superko when ko is on.
func (s *ServerCore) legalLocked(p *play, m int) string {
	st := p.state
	if m >= 0 && (m >= len(st.Cells) || st.Cells[m] != Open) {
		return "occupied"
	}
	if !p.geom.IsLegal(st, m) {
		return "ko"
	}
	if m >= 0 && st.KoOn {
		t := st.Clone()
		NewWork(p.geom).Play(t, m)
		if p.seen(t) {
			return "superko"
		}
	}
	return ""
}

// situation is the exact board plus the seat to move: the collision-safe
// equality behind the Zobrist key (situational superko).
func situation(s *State) []byte {
	b := make([]byte, len(s.Cells)+1)
	for i, c := range s.Cells {
		b[i] = byte(c)
	}
	b[len(s.Cells)] = byte(s.ToMove)
	return b
}

func (p *play) seen(s *State) bool {
	exact := situation(s)
	for _, x := range p.history[p.geom.Key(s)] {
		if string(x) == string(exact) {
			return true
		}
	}
	return false
}

func (p *play) remember(s *State) {
	if !p.seen(s) {
		k := p.geom.Key(s)
		p.history[k] = append(p.history[k], situation(s))
	}
}

// applyLocked ends the current turn with m, records it and starts the next turn.
// Every turn-ending path calls it under s.mu after checking turnSeq.
func (s *ServerCore) applyLocked(g *game, m int, source string, search *SearchSummary) MoveRecord {
	p := g.play
	st := p.state
	n := st.ToMove
	rec := MoveRecord{MoveNo: uint32(st.MoveNo), Seat: uint32(n), Source: source, Search: search, Victims: make([]uint32, g.seats)}
	switch {
	case m >= 0:
		x, y := p.geom.XY(m)
		rec.Kind, rec.X, rec.Y = "place", uint32(x), uint32(y)
	case m == MoveResign:
		rec.Kind = "resign"
	case m == MoveTimeout:
		rec.Kind = "timeout"
	default:
		rec.Kind = "pass"
	}
	res := NewWork(p.geom).Play(st, m)
	for v, c := range res.Victims {
		rec.Victims[v-1] = uint32(c)
		p.bowl[v][n] += c
	}
	if res.Suicide > 0 {
		rec.Suicide = uint32(res.Suicide)
		p.bowl[n][n] += res.Suicide
	}
	rec.Captured = uint32(res.Captured + res.Suicide)
	p.remember(st)
	if len(p.moves) < MaxMoveRecords {
		p.moves = append(p.moves, rec)
	}
	if p.timer != nil {
		p.timer.Stop()
		p.timer = nil
	}
	p.turnSeq++
	s.beginTurnLocked(g)
	return rec
}

// beginTurnLocked starts the next turn: finishes a terminal game, passes for a
// resigned seat, otherwise arms the controller's clock.
func (s *ServerCore) beginTurnLocked(g *game) {
	p := g.play
	if p.geom.Terminal(p.state) {
		s.finishLocked(g)
		return
	}
	if p.state.IsOut(p.state.ToMove) {
		s.applyLocked(g, MovePass, "resigned", nil)
		return
	}
	p.turnBegan = s.clock()
	s.armTurnLocked(g, true)
}

// armTurnLocked starts the timer and, for bot-controlled seats, a bot search for
// the current turn revision. fresh is false when an autopilot switch rearms the
// same turn: a person's deadline then still counts from turnBegan.
func (s *ServerCore) armTurnLocked(g *game, fresh bool) {
	if s.closed {
		return
	}
	p := g.play
	seq := p.turnSeq
	gameID := g.id
	n := p.state.ToMove
	var wait time.Duration
	if g.seatInfo[n-1].botControlled() {
		budget := s.botBudget(g)
		p.botStart = s.clock()
		wait = budget*2 + time.Second
		job := botJob{gameID: gameID, seq: seq, geom: p.geom, state: p.state.Clone(), budget: budget,
			params: SearchParams{C: float64(g.exploreMilli) / 1000, T: float64(g.softness), Mode: g.rewardMode, Teams: g.teamArray()}}
		job.params.History = make(map[uint64]bool, len(p.history)) // advisory for search; the transition re-checks exactly
		for k := range p.history {
			job.params.History[k] = true
		}
		s.bots.dispatch(s, job)
	} else {
		wait = s.humanLimit(g)
		if !fresh {
			wait -= s.clock().Sub(p.turnBegan)
		}
		if wait <= 0 {
			s.applyLocked(g, MoveTimeout, "deadline", nil)
			return
		}
	}
	p.timer = time.AfterFunc(wait, func() { s.timeout(gameID, seq) })
}

// teamArray returns per-seat team numbers, or nil when every seat is alone.
func (g *game) teamArray() []int {
	t := make([]int, g.seats)
	seen := map[int]bool{}
	shared := false
	for i, st := range g.seatInfo {
		t[i] = st.team
		if seen[st.team] {
			shared = true
		}
		seen[st.team] = true
	}
	if !shared {
		return nil
	}
	return t
}

// applyBotResult is the server side of BotMoveChosen: it applies the result only
// for the same game, seat and turn revision, while a bot still controls the seat.
func (s *ServerCore) applyBotResult(job botJob, res SearchResult) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g, _ := s.findGame(job.gameID)
	if g == nil || g.status != GamePlaying || g.play.turnSeq != job.seq {
		return
	}
	st := &g.seatInfo[g.play.state.ToMove-1]
	if !st.botControlled() {
		return
	}
	m := res.Move
	if s.legalLocked(g.play, m) != "" {
		m = MovePass
	}
	source := "bot"
	if st.autopilot {
		source = "autopilot"
	}
	s.applyLocked(g, m, source, summarize(g.play.geom, job.state, res))
}

func summarize(geom *Geom, root *State, res SearchResult) *SearchSummary {
	k := root.K
	out := &SearchSummary{Playouts: uint32(res.Iterations), Ms: uint32(res.Elapsed / time.Millisecond), Guard: res.Guard,
		Candidates: []CandidateView{}, RootProjMilli: make([]int32, k), RootOutlookPermille: make([]int32, k)}
	for i := 1; i <= k; i++ {
		out.RootProjMilli[i-1] = int32(res.RootProj[i] * 1000)
		out.RootOutlookPermille[i-1] = int32(res.RootQ[i] * 1000)
	}
	for _, c := range res.Top {
		v := CandidateView{Visits: uint32(c.Visits), RewardPermille: int32(c.Reward * 1000), OutlookPermille: make([]int32, k), ProjMilli: make([]int32, k)}
		if c.Move >= 0 {
			x, y := geom.XY(c.Move)
			v.Kind, v.X, v.Y = "place", uint32(x), uint32(y)
		} else {
			v.Kind = "pass"
		}
		for i := 1; i <= k; i++ {
			v.OutlookPermille[i-1] = int32(c.Outlook[i] * 1000)
			v.ProjMilli[i-1] = int32(c.Proj[i] * 1000)
		}
		out.Candidates = append(out.Candidates, v)
	}
	return out
}

// timeout turns an unanswered turn into a Timeout (a pass that does not end the game).
func (s *ServerCore) timeout(gameID string, seq uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g, _ := s.findGame(gameID)
	if g == nil || g.status != GamePlaying || g.play.turnSeq != seq {
		return
	}
	s.applyLocked(g, MoveTimeout, "deadline", nil)
}

func (s *ServerCore) finishLocked(g *game) {
	p := g.play
	g.status = GameFinished
	if p.timer != nil {
		p.timer.Stop()
		p.timer = nil
	}
	switch {
	case p.state.Abandoned():
		p.endReason = "abandoned: a full round of timeouts"
	case p.state.MoveNo >= p.geom.N*p.geom.N*3:
		p.endReason = "move cap reached"
	default:
		p.endReason = "every player passed"
	}
	for id := range g.proposals {
		s.withdrawLocked(g, id, "the game finished")
	}
	views := s.seatViewsLocked(g, nil)
	teams := teamViews(views)
	winners := winnersOf(views)
	parts := []string{}
	for _, t := range teams {
		names := []string{}
		for _, n := range t.Seats {
			names = append(names, views[n-1].Player)
		}
		parts = append(parts, fmt.Sprintf("%s %d", strings.Join(names, "+"), t.Score))
	}
	wn := []string{}
	for _, w := range winners {
		wn = append(wn, views[w-1].Player)
	}
	g.chat = appendBoundedGame(g.chat, GameChat{GameID: g.id, Sender: "server", Body: "Game over (" + p.endReason + "). " + strings.Join(parts, ", ") + ". Winner: " + strings.Join(wn, ", "), TimeMS: s.clock().UnixMilli()})
}

// winnersOf returns the seats of the team(s) with the highest team score among
// teams with at least one member who has not resigned.
func winnersOf(v []SeatView) []uint32 {
	best := int32(-1 << 30)
	teams := teamViews(v)
	eligible := map[uint32]bool{}
	for _, t := range teams {
		for _, n := range t.Seats {
			if !v[n-1].Resigned {
				eligible[t.Team] = true
			}
		}
		if eligible[t.Team] && t.Score > best {
			best = t.Score
		}
	}
	out := []uint32{}
	for _, t := range teams {
		if eligible[t.Team] && t.Score == best {
			out = append(out, t.Seats...)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func teamViews(v []SeatView) []TeamView {
	idx := map[uint32]int{}
	out := []TeamView{}
	for _, x := range v {
		i, ok := idx[x.Team]
		if !ok {
			i = len(out)
			idx[x.Team] = i
			out = append(out, TeamView{Team: x.Team})
		}
		out[i].Seats = append(out[i].Seats, x.Seat)
		out[i].Territory += x.Territory
		out[i].Losses += x.Losses
		out[i].Score += x.Score
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Team < out[b].Team })
	return out
}

func (s *ServerCore) seatViewsLocked(g *game, sc *Score) []SeatView {
	views := make([]SeatView, g.seats)
	for i, st := range g.seatInfo {
		views[i] = SeatView{Seat: uint32(i + 1), Player: st.player, Controller: st.viewController(), Team: uint32(st.team), LossesBy: make([]uint32, g.seats)}
	}
	if g.play == nil {
		return views
	}
	if sc == nil {
		x := NewWork(g.play.geom).Score(g.play.state, false)
		sc = &x
	}
	for i := range views {
		views[i].Territory = int32(sc.Territory[i+1])
		views[i].Losses = int32(g.play.state.Losses[i+1])
		views[i].Score = int32(sc.Scores[i+1])
		views[i].Resigned = g.play.state.IsOut(i + 1)
		for c := 1; c <= g.seats; c++ {
			views[i].LossesBy[c-1] = uint32(g.play.bowl[i+1][c])
		}
	}
	return views
}

// ---------- team merges ----------

// personsIn lists the people seated in team t (autopilot seats included).
func (g *game) personsIn(t int) []string {
	out := []string{}
	for _, st := range g.seatInfo {
		if st.team == t && st.controller == CtlPerson {
			out = append(out, st.player)
		}
	}
	return out
}

func (g *game) teamExists(t int) bool {
	for _, st := range g.seatInfo {
		if st.team == t {
			return true
		}
	}
	return false
}

// Requirement refs: grammar:propose_merge; task:team_merge; proof:merges never happen without consent.
func (s *ServerCore) proposeMerge(r ProposeMerge) any {
	return s.cached(r.SessionID, "propose_merge", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "propose_merge")
		}
		if g.status != GamePlaying {
			return reject(r.RequestID, "not_playing", "propose_merge")
		}
		n := g.seatOf(identity)
		if n == 0 {
			return reject(r.RequestID, "not_seated", "propose_merge")
		}
		a, b := g.seatInfo[n-1].team, int(r.OtherTeam)
		if a == b || !g.teamExists(b) {
			return reject(r.RequestID, "invalid_team", "propose_merge")
		}
		if len(g.personsIn(b)) == 0 {
			return reject(r.RequestID, "no_person_on_team", "propose_merge")
		}
		for _, pr := range g.proposals {
			if (pr.a == a && pr.b == b) || (pr.a == b && pr.b == a) {
				return reject(r.RequestID, "duplicate_proposal", "propose_merge")
			}
		}
		g.nextProposal++
		pr := &proposal{id: g.nextProposal, a: a, b: b, proposer: identity, accepted: map[string]bool{identity: true}}
		if g.proposals == nil {
			g.proposals = map[uint32]*proposal{}
		}
		g.proposals[pr.id] = pr
		g.chat = appendBoundedGame(g.chat, GameChat{GameID: g.id, Sender: "server", Body: fmt.Sprintf("%s proposes merging team %d with team %d. Every person on both teams must accept.", identity, a, b), TimeMS: s.clock().UnixMilli()})
		return MergeProposed{GameID: g.id, ProposalID: pr.id, TeamA: uint32(a), TeamB: uint32(b), RequestID: r.RequestID}
	})
}

// Requirement refs: grammar:respond_merge; task:team_merge; proof:merges never happen without consent.
func (s *ServerCore) respondMerge(r RespondMerge) any {
	return s.cached(r.SessionID, "respond_merge", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "respond_merge")
		}
		if g.status != GamePlaying {
			return reject(r.RequestID, "not_playing", "respond_merge")
		}
		pr := g.proposals[r.ProposalID]
		if pr == nil {
			return reject(r.RequestID, "no_proposal", "respond_merge")
		}
		n := g.seatOf(identity)
		if n == 0 || (g.seatInfo[n-1].team != pr.a && g.seatInfo[n-1].team != pr.b) {
			return reject(r.RequestID, "not_on_team", "respond_merge")
		}
		if !r.Accept {
			s.withdrawLocked(g, pr.id, identity+" declined")
			return MergeResponded{GameID: g.id, ProposalID: pr.id, Status: "withdrawn", RequestID: r.RequestID}
		}
		pr.accepted[identity] = true
		for _, p := range append(g.personsIn(pr.a), g.personsIn(pr.b)...) {
			if !pr.accepted[p] {
				return MergeResponded{GameID: g.id, ProposalID: pr.id, Status: "pending", RequestID: r.RequestID}
			}
		}
		s.mergeLocked(g, pr)
		return MergeResponded{GameID: g.id, ProposalID: pr.id, Status: "merged", RequestID: r.RequestID}
	})
}

// mergeLocked permanently merges both teams into the smaller team number and
// withdraws every other proposal that involved either team.
func (s *ServerCore) mergeLocked(g *game, pr *proposal) {
	to, from := pr.a, pr.b
	if from < to {
		to, from = from, to
	}
	seats := []string{}
	for i := range g.seatInfo {
		if g.seatInfo[i].team == from {
			g.seatInfo[i].team = to
		}
		if g.seatInfo[i].team == to {
			seats = append(seats, g.seatInfo[i].player)
		}
	}
	delete(g.proposals, pr.id)
	for id, other := range g.proposals {
		if other.a == pr.a || other.a == pr.b || other.b == pr.a || other.b == pr.b {
			s.withdrawLocked(g, id, "a team changed")
		}
	}
	g.chat = appendBoundedGame(g.chat, GameChat{GameID: g.id, Sender: "server", Body: fmt.Sprintf("Teams merged into team %d: %s.", to, strings.Join(seats, ", ")), TimeMS: s.clock().UnixMilli()})
}

func (s *ServerCore) withdrawLocked(g *game, id uint32, reason string) {
	pr := g.proposals[id]
	if pr == nil {
		return
	}
	delete(g.proposals, id)
	g.chat = appendBoundedGame(g.chat, GameChat{GameID: g.id, Sender: "server", Body: fmt.Sprintf("Merge of team %d with team %d withdrawn: %s.", pr.a, pr.b, reason), TimeMS: s.clock().UnixMilli()})
}

// Requirement refs: grammar:game_state; proof:game_state never crosses authority or scope.
func (s *ServerCore) gameState(r GetGameState) any {
	return s.cached(r.SessionID, "game_state", r.RequestID, r, func(identity string) any {
		s.mu.RLock()
		defer s.mu.RUnlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "game_state")
		}
		out := GameState{GameID: g.id, GameName: g.name, Status: g.status, Creator: g.creator, BoardSize: uint32(g.boardSize),
			KoOn: koEnabled(g.koRule, g.seats), TurnDeadlineMS: g.turnDeadlineMs, BotMS: g.botMs, RequestID: r.RequestID,
			ExploreMilli: g.exploreMilli, RewardMode: g.rewardMode, Softness: g.softness,
			Cells: []int32{}, Owner: []int32{}, Moves: []MoveRecord{}, Winners: []uint32{}, Proposals: []MergeView{}}
		ids := make([]int, 0, len(g.proposals))
		for id := range g.proposals {
			ids = append(ids, int(id))
		}
		sort.Ints(ids)
		for _, id := range ids {
			pr := g.proposals[uint32(id)]
			mv := MergeView{ProposalID: pr.id, TeamA: uint32(pr.a), TeamB: uint32(pr.b), Proposer: pr.proposer, AcceptedBy: []string{}, WaitingFor: []string{}}
			for _, p := range append(g.personsIn(pr.a), g.personsIn(pr.b)...) {
				if pr.accepted[p] {
					mv.AcceptedBy = append(mv.AcceptedBy, p)
				} else {
					mv.WaitingFor = append(mv.WaitingFor, p)
				}
			}
			out.Proposals = append(out.Proposals, mv)
		}
		if g.play == nil {
			out.Seats = s.seatViewsLocked(g, nil)
			out.Teams = teamViews(out.Seats)
			return out
		}
		p := g.play
		sc := NewWork(p.geom).Score(p.state, true)
		out.Seats = s.seatViewsLocked(g, &sc)
		out.Teams = teamViews(out.Seats)
		out.KoOn = p.state.KoOn
		out.MoveNo = uint32(p.state.MoveNo)
		out.ToMove = uint32(p.state.ToMove)
		for _, pt := range p.geom.pts {
			out.Cells = append(out.Cells, int32(p.state.Cells[pt]))
			out.Owner = append(out.Owner, int32(sc.Owner[pt]))
		}
		if int(r.SinceMove) < len(p.moves) {
			out.Moves = append(out.Moves, p.moves[r.SinceMove:]...)
		}
		if g.status == GamePlaying {
			var left time.Duration
			if g.seatInfo[p.state.ToMove-1].botControlled() {
				left = s.botBudget(g) - s.clock().Sub(p.botStart)
			} else {
				left = s.humanLimit(g) - s.clock().Sub(p.turnBegan)
			}
			if left > 0 {
				out.RemainingMS = uint64(left / time.Millisecond)
			}
		} else {
			out.Winners = winnersOf(out.Seats)
			out.EndReason = p.endReason
			out.ToMove = 0
		}
		return out
	})
}

// Close stops timers and waits for running bot searches, for tests and shutdown.
func (s *ServerCore) Close() {
	s.mu.Lock()
	if !s.closed {
		s.closed = true
		s.bots.close()
		for _, rm := range s.rooms {
			for _, g := range rm.games {
				if g.play != nil && g.play.timer != nil {
					g.play.timer.Stop()
				}
			}
		}
	}
	s.mu.Unlock()
	s.bots.wait()
}

func (r RequestRejected) withScope(scope string) RequestRejected {
	r.ScopeID = scope
	return r
}
