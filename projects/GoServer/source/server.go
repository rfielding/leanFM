package goserver

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

const (
	MaxNameRunes     = 128
	MaxSessions      = 100
	MaxRooms         = 16
	MaxGames         = 64
	MaxReplayEntries = 128
	MaxChatRunes     = 4000
	MaxChatEntries   = 100
)

// Requirement refs: goserver message schemas; explicit JSON mapping for the local inspection harness.
// Requirement refs: grammar:create_room; authenticated, correlated creation.
type CreateRoom struct {
	SessionID string `json:"sessionId"`
	RoomName  string `json:"roomName"`
	RequestID uint64 `json:"requestId"`
}
type RoomCreated struct {
	RoomID    string `json:"roomId"`
	RequestID uint64 `json:"requestId"`
}
type ListRooms struct {
	SessionID string `json:"sessionId"`
	RequestID uint64 `json:"requestId"`
}
type RoomsListed struct {
	RoomIDs   []string `json:"roomIds"`
	RequestID uint64   `json:"requestId"`
}
type EnterRoom struct {
	SessionID string `json:"sessionId"`
	RoomID    string `json:"roomId"`
	RequestID uint64 `json:"requestId"`
}
type RoomEntered struct {
	RoomID    string   `json:"roomId"`
	GameIDs   []string `json:"gameIds"`
	RequestID uint64   `json:"requestId"`
}
type ListGames struct {
	RoomID    string `json:"roomId"`
	SessionID string `json:"sessionId"`
	RequestID uint64 `json:"requestId"`
}
type GamesListed struct {
	Games     []GameListed `json:"games"`
	RequestID uint64       `json:"requestId"`
	RoomID    string       `json:"roomId"`
}

// Requirement refs: grammar:create_game; board, bot and seat settings as in the N-Player Go Lab setup.
type CreateGame struct {
	SessionID      string     `json:"sessionId"`
	RoomID         string     `json:"roomId"`
	GameName       string     `json:"gameName"`
	BoardSize      uint32     `json:"boardSize"`
	Seats          uint32     `json:"seats"`
	TurnDeadlineMS uint64     `json:"turnDeadlineMs"`
	KoRule         int32      `json:"koRule"`
	BotMS          uint64     `json:"botMs"`
	ExploreMilli   uint32     `json:"exploreMilli"`
	RewardMode     string     `json:"rewardMode"`
	Softness       uint32     `json:"softness"`
	SeatPlan       []SeatPlan `json:"seatPlan"`
	RequestID      uint64     `json:"requestId"`
}
type GameCreated struct {
	GameName       string     `json:"gameName"`
	GameID         string     `json:"gameId"`
	RoomID         string     `json:"roomId"`
	Creator        string     `json:"creator"`
	Status         string     `json:"status"`
	BoardSize      uint32     `json:"boardSize"`
	Seats          uint32     `json:"seats"`
	TurnDeadlineMS uint64     `json:"turnDeadlineMs"`
	KoRule         int32      `json:"koRule"`
	BotMS          uint64     `json:"botMs"`
	ExploreMilli   uint32     `json:"exploreMilli"`
	RewardMode     string     `json:"rewardMode"`
	Softness       uint32     `json:"softness"`
	SeatPlan       []SeatPlan `json:"seatPlan"`
	RequestID      uint64     `json:"requestId"`
}
type JoinGame struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	RequestID uint64 `json:"requestId"`
}
type GameJoined struct {
	GameID       string   `json:"gameId"`
	Participants []string `json:"participants"`
	RequestID    uint64   `json:"requestId"`
}
type SendRoomChat struct {
	SessionID string `json:"sessionId"`
	RoomID    string `json:"roomId"`
	Body      string `json:"body"`
	RequestID uint64 `json:"requestId"`
}
type RoomChat struct {
	RoomID    string `json:"roomId"`
	Sender    string `json:"sender"`
	Body      string `json:"body"`
	TimeMS    int64  `json:"timeMs"`
	RequestID uint64 `json:"requestId"`
}
type SendGameChat struct {
	SessionID string `json:"sessionId"`
	GameID    string `json:"gameId"`
	Body      string `json:"body"`
	RequestID uint64 `json:"requestId"`
}
type GameChat struct {
	GameID    string `json:"gameId"`
	Sender    string `json:"sender"`
	Body      string `json:"body"`
	TimeMS    int64  `json:"timeMs"`
	RequestID uint64 `json:"requestId"`
}
type RequestRejected struct {
	RequestID uint64 `json:"requestId"`
	Code      string `json:"code"`
	Task      string `json:"task"`
	ScopeID   string `json:"scopeId"`
}
type GameListed struct {
	GameName    string `json:"gameName"`
	GameID      string `json:"gameId"`
	Creator     string `json:"creator"`
	Status      string `json:"status"`
	BoardSize   uint32 `json:"boardSize"`
	Seats       uint32 `json:"seats"`
	SeatsFilled uint32 `json:"seatsFilled"`
}
type clock func() time.Time
type room struct {
	id      string
	members map[string]bool
	games   map[string]*game
	chat    []RoomChat
}
type game struct {
	id, roomID, creator, name, status string
	members                           map[string]bool
	chat                              []GameChat
	boardSize                         int
	seats                             int
	turnDeadlineMs                    uint64
	botMs                             uint64
	koRule                            int
	exploreMilli                      uint32
	rewardMode                        string
	softness                          uint32
	seatInfo                          []seat
	proposals                         map[uint32]*proposal
	nextProposal                      uint32
	play                              *play
}
type cachedResult struct {
	fingerprint string
	response    any
}

// Requirement refs: property:create_room authorized correlated result.
// Retain accepted mutation results; reject new admission when full, never evict
// a result and reapply an old mutation.
type sessionCache struct {
	entries map[string]cachedResult
	order   []string
}

// readOnlyTasks never mutate state, so their request IDs do not consume the
// per-session replay window (requirement: duplicate *mutation* IDs replay).
var readOnlyTasks = map[string]bool{"list_rooms": true, "list_games": true, "game_state": true}

type ServerCore struct {
	mu       sync.RWMutex
	opMu     sync.Mutex
	clock    clock
	seq      atomic.Uint64
	sessions map[string]string
	rooms    map[string]*room
	cache    map[string]*sessionCache
	bots     *BotPool
	closed   bool
	// test hooks: shorter bot budgets and human turn limits
	botBudgetOverride time.Duration
	turnLimit         time.Duration
}

func NewServer() *ServerCore {
	s := &ServerCore{clock: time.Now, sessions: make(map[string]string), rooms: make(map[string]*room), cache: make(map[string]*sessionCache), bots: newBotPool(botSlotCount())}
	s.rooms["lobby"] = &room{id: "lobby", members: make(map[string]bool), games: make(map[string]*game)}
	return s
}

// Requirement refs: goserver identity boundaries and finite Server actor resources.
func (s *ServerCore) IssueSession(identity string) (string, error) {
	if !validName(identity) {
		return "", errors.New("invalid identity")
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", errors.New("session randomness unavailable")
	}
	token := hex.EncodeToString(secret)
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.sessions) >= MaxSessions {
		return "", errors.New("session capacity reached")
	}
	for _, existing := range s.sessions {
		if existing == identity {
			return "", errors.New("identity already in use; choose another local demo name")
		}
	}
	s.sessions[token] = identity
	return token, nil
}

func (s *ServerCore) AddRoom(roomID string) error {
	if !validName(roomID) {
		return errors.New("invalid room id")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.rooms[roomID]; ok {
		return errors.New("room exists")
	}
	if len(s.rooms) >= MaxRooms {
		return errors.New("room capacity reached")
	}
	s.rooms[roomID] = &room{id: roomID, members: make(map[string]bool), games: make(map[string]*game)}
	return nil
}

// Legacy provisioning helper retained for existing callers. The browser uses
// Handle(CreateRoom{...}) for the accepted correlated/replay-safe operation.
// Creation is separate from EnterRoom membership.
func (s *ServerCore) CreateRoom(session, roomID string) error {
	if _, ok := s.identityFor(session); !ok {
		return errors.New("unauthorized")
	}
	return s.AddRoom(roomID)
}

// RoomChatHistory delivers the retained RoomChat events of one room to a
// current member only (requirement: chat is delivered only inside its scope).
func (s *ServerCore) RoomChatHistory(session, roomID string) ([]RoomChat, error) {
	identity, ok := s.identityFor(session)
	if !ok {
		return nil, errors.New("unauthorized")
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	rm, ok := s.rooms[roomID]
	if !ok || !rm.members[identity] {
		return nil, errors.New("forbidden")
	}
	return append([]RoomChat{}, rm.chat...), nil
}

// GameChatHistory delivers the retained GameChat events and participant list of
// one game to a current game member only.
func (s *ServerCore) GameChatHistory(session, gameID string) ([]GameChat, []string, error) {
	identity, ok := s.identityFor(session)
	if !ok {
		return nil, nil, errors.New("unauthorized")
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	g, _ := s.findGame(gameID)
	if g == nil || !g.members[identity] {
		return nil, nil, errors.New("forbidden")
	}
	participants := make([]string, 0, len(g.members))
	for p := range g.members {
		participants = append(participants, p)
	}
	sortStrings(participants)
	return append([]GameChat{}, g.chat...), participants, nil
}

func (s *ServerCore) identityFor(session string) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	identity, ok := s.sessions[session]
	return identity, ok
}

func (s *ServerCore) Handle(request any) any {
	switch r := request.(type) {
	case CreateRoom:
		return s.createRoom(r)
	case ListRooms:
		return s.listRooms(r)
	case EnterRoom:
		return s.enterRoom(r)
	case ListGames:
		return s.listGames(r)
	case CreateGame:
		return s.createGame(r)
	case JoinGame:
		return s.joinGame(r)
	case SendRoomChat:
		return s.sendRoomChat(r)
	case SendGameChat:
		return s.sendGameChat(r)
	case TakeSeat:
		return s.takeSeat(r)
	case StartGame:
		return s.startGame(r)
	case PlayMove:
		return s.playMove(r)
	case GetGameState:
		return s.gameState(r)
	case SetSeatPlan:
		return s.setSeatPlan(r)
	case LeaveSeat:
		return s.leaveSeat(r)
	case SetAutopilot:
		return s.setAutopilot(r)
	case ProposeMerge:
		return s.proposeMerge(r)
	case RespondMerge:
		return s.respondMerge(r)
	default:
		return RequestRejected{Code: "unsupported_request", Task: "unknown", ScopeID: ""}
	}
}

// Requirement refs: grammar:create_room; proof:create_room never crosses authority or scope.
func (s *ServerCore) createRoom(r CreateRoom) any {
	return s.cached(r.SessionID, "create_room", r.RequestID, r, func(identity string) any {
		name := strings.TrimSpace(r.RoomName)
		if !validName(name) {
			return reject(r.RequestID, "invalid_name", "create_room")
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if _, exists := s.rooms[name]; exists {
			return reject(r.RequestID, "room_exists", "create_room")
		}
		if len(s.rooms) >= MaxRooms {
			return reject(r.RequestID, "busy", "create_room")
		}
		s.rooms[name] = &room{id: name, members: make(map[string]bool), games: make(map[string]*game)}
		return RoomCreated{RoomID: name, RequestID: r.RequestID}
	})
}

func (s *ServerCore) listRooms(r ListRooms) any {
	return s.cached(r.SessionID, "list_rooms", r.RequestID, r, func(identity string) any {
		s.mu.RLock()
		defer s.mu.RUnlock()
		ids := make([]string, 0, len(s.rooms))
		for id := range s.rooms {
			ids = append(ids, id)
		}
		sortStrings(ids)
		return RoomsListed{RoomIDs: ids, RequestID: r.RequestID}
	})
}

func (s *ServerCore) enterRoom(r EnterRoom) any {
	return s.cached(r.SessionID, "enter_room", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		rm, ok := s.rooms[r.RoomID]
		if !ok {
			return reject(r.RequestID, "not_found", "enter_room")
		}
		rm.members[identity] = true
		return RoomEntered{RoomID: rm.id, GameIDs: gameIDs(rm), RequestID: r.RequestID}
	})
}

func (s *ServerCore) listGames(r ListGames) any {
	return s.cached(r.SessionID, "list_games", r.RequestID, r, func(identity string) any {
		s.mu.RLock()
		defer s.mu.RUnlock()
		rm, ok := s.rooms[r.RoomID]
		if !ok || !rm.members[identity] {
			return reject(r.RequestID, "forbidden", "list_games")
		}
		games := make([]GameListed, 0, len(rm.games))
		for _, g := range rm.games {
			filled := 0
			for _, st := range g.seatInfo {
				if st.controller != CtlOpen {
					filled++
				}
			}
			games = append(games, GameListed{GameName: g.name, GameID: g.id, Creator: g.creator, Status: g.status, BoardSize: uint32(g.boardSize), Seats: uint32(g.seats), SeatsFilled: uint32(filled)})
		}
		sortGameListings(games)
		return GamesListed{Games: games, RoomID: rm.id, RequestID: r.RequestID}
	})
}

// Requirement refs: grammar:create_game; proof:create_game never crosses authority or scope.
// The game opens with empty seats; the creator and other members take seats, and
// StartGame fills every remaining seat with a server-side MCTS bot.
func (s *ServerCore) createGame(r CreateGame) any {
	return s.cached(r.SessionID, "create_game", r.RequestID, r, func(identity string) any {
		name := strings.TrimSpace(r.GameName)
		if !validName(name) {
			return reject(r.RequestID, "invalid_name", "create_game")
		}
		cfg, code := normalizeGameParams(r)
		if code != "" {
			return reject(r.RequestID, code, "create_game")
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		rm, ok := s.rooms[r.RoomID]
		if !ok || !rm.members[identity] {
			return reject(r.RequestID, "forbidden", "create_game")
		}
		count := 0
		for _, room := range s.rooms {
			count += len(room.games)
		}
		if count >= MaxGames {
			return reject(r.RequestID, "busy", "create_game")
		}
		id := s.newID("game")
		g := &game{id: id, roomID: rm.id, creator: identity, name: name, status: GameOpen, members: map[string]bool{identity: true},
			boardSize: cfg.board, seats: cfg.seats, turnDeadlineMs: cfg.deadline, botMs: cfg.bot, koRule: cfg.ko,
			exploreMilli: cfg.explore, rewardMode: cfg.mode, softness: cfg.softness, seatInfo: cfg.plan}
		rm.games[id] = g
		plan := make([]SeatPlan, cfg.seats)
		for i, st := range cfg.plan {
			plan[i] = SeatPlan{Seat: uint32(i + 1), Controller: st.controller, Team: uint32(st.team)}
		}
		return GameCreated{GameName: name, GameID: id, RoomID: rm.id, Creator: identity, Status: GameOpen, BoardSize: uint32(cfg.board), Seats: uint32(cfg.seats), TurnDeadlineMS: cfg.deadline, KoRule: int32(cfg.ko), BotMS: cfg.bot, ExploreMilli: cfg.explore, RewardMode: cfg.mode, Softness: cfg.softness, SeatPlan: plan, RequestID: r.RequestID}
	})
}

func (s *ServerCore) joinGame(r JoinGame) any {
	return s.cached(r.SessionID, "join_game", r.RequestID, r, func(identity string) any {
		s.mu.Lock()
		defer s.mu.Unlock()
		g, rm := s.findGame(r.GameID)
		if g == nil || rm == nil || !rm.members[identity] {
			return reject(r.RequestID, "forbidden", "join_game")
		}
		g.members[identity] = true
		participants := make([]string, 0, len(g.members))
		for p := range g.members {
			participants = append(participants, p)
		}
		sortStrings(participants)
		return GameJoined{GameID: g.id, Participants: participants, RequestID: r.RequestID}
	})
}

func (s *ServerCore) sendRoomChat(r SendRoomChat) any {
	return s.cached(r.SessionID, "room_chat", r.RequestID, r, func(identity string) any {
		if !validChat(r.Body) {
			return reject(r.RequestID, "invalid_body", "room_chat")
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		rm, ok := s.rooms[r.RoomID]
		if !ok || !rm.members[identity] {
			return reject(r.RequestID, "forbidden", "room_chat")
		}
		msg := RoomChat{RoomID: rm.id, Sender: identity, Body: r.Body, TimeMS: s.clock().UnixMilli(), RequestID: r.RequestID}
		rm.chat = appendBoundedRoom(rm.chat, msg)
		return msg
	})
}

func (s *ServerCore) sendGameChat(r SendGameChat) any {
	return s.cached(r.SessionID, "game_chat", r.RequestID, r, func(identity string) any {
		if !validChat(r.Body) {
			return reject(r.RequestID, "invalid_body", "game_chat")
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		g, _ := s.findGame(r.GameID)
		if g == nil || !g.members[identity] {
			return reject(r.RequestID, "forbidden", "game_chat")
		}
		msg := GameChat{GameID: g.id, Sender: identity, Body: r.Body, TimeMS: s.clock().UnixMilli(), RequestID: r.RequestID}
		g.chat = appendBoundedGame(g.chat, msg)
		return msg
	})
}

// cached authenticates the session, then (for mutating tasks) serializes the
// action and records its result with bounded per-session mutation admission so a
// duplicate request ID returns the original result and a conflicting reuse is
// rejected. Read-only tasks are authenticated but not recorded.
func (s *ServerCore) cached(session, task string, requestID uint64, request any, action func(string) any) any {
	if requestID == 0 {
		return reject(0, "invalid_request_id", task)
	}
	identity, authenticated := s.identityFor(session)
	if !authenticated {
		return reject(requestID, "unauthorized", task)
	}
	if readOnlyTasks[task] {
		return action(identity)
	}
	fingerprint := fingerprint(request)
	key := task + ":" + fmt.Sprint(requestID)
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.mu.Lock()
	sc := s.cache[session]
	if sc == nil {
		sc = &sessionCache{entries: make(map[string]cachedResult)}
		s.cache[session] = sc
	}
	if old, ok := sc.entries[key]; ok {
		s.mu.Unlock()
		if old.fingerprint == fingerprint {
			return old.response
		}
		return reject(requestID, "request_id_conflict", task)
	}
	if len(sc.entries) >= MaxReplayEntries {
		s.mu.Unlock()
		return reject(requestID, "busy", task)
	}
	s.mu.Unlock()
	response := action(identity)
	s.mu.Lock()
	sc.entries[key] = cachedResult{fingerprint: fingerprint, response: response}
	sc.order = append(sc.order, key)
	s.mu.Unlock()
	return response
}

func (s *ServerCore) findGame(id string) (*game, *room) {
	for _, rm := range s.rooms {
		if g, ok := rm.games[id]; ok {
			return g, rm
		}
	}
	return nil, nil
}
func (s *ServerCore) newID(prefix string) string {
	n := s.seq.Add(1)
	return fmt.Sprintf("%s-%d", prefix, n)
}
func reject(id uint64, code, task string) RequestRejected {
	return RequestRejected{RequestID: id, Code: code, Task: task}
}
func validName(v string) bool {
	return v != "" && utf8.ValidString(v) && utf8.RuneCountInString(v) <= MaxNameRunes
}
func validChat(v string) bool {
	return v != "" && utf8.ValidString(v) && utf8.RuneCountInString(v) <= MaxChatRunes
}
func gameIDs(r *room) []string {
	ids := make([]string, 0, len(r.games))
	for id := range r.games {
		ids = append(ids, id)
	}
	sortStrings(ids)
	return ids
}
func appendBoundedRoom(v []RoomChat, x RoomChat) []RoomChat {
	v = append(v, x)
	if len(v) > MaxChatEntries {
		v = v[len(v)-MaxChatEntries:]
	}
	return v
}
func appendBoundedGame(v []GameChat, x GameChat) []GameChat {
	v = append(v, x)
	if len(v) > MaxChatEntries {
		v = v[len(v)-MaxChatEntries:]
	}
	return v
}
func fingerprint(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func sortStrings(v []string) {
	for i := 1; i < len(v); i++ {
		for j := i; j > 0 && v[j] < v[j-1]; j-- {
			v[j], v[j-1] = v[j-1], v[j]
		}
	}
}
func sortGameListings(v []GameListed) {
	for i := 1; i < len(v); i++ {
		for j := i; j > 0 && strings.Compare(v[j].GameID, v[j-1].GameID) < 0; j-- {
			v[j], v[j-1] = v[j-1], v[j]
		}
	}
}
