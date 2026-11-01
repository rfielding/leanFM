package goserver

import (
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
	MaxNameRunes = 128
	MaxChatRunes = 4000
	MaxChatEntries = 100
)

type ListRooms struct { SessionID string; RequestID uint64 }
type RoomsListed struct { RoomIDs []string; RequestID uint64 }
type EnterRoom struct { SessionID, RoomID string; RequestID uint64 }
type RoomEntered struct { RoomID string; GameIDs []string; RequestID uint64 }
type ListGames struct { RoomID, SessionID string; RequestID uint64 }
type GamesListed struct { Games []GameListed; RequestID uint64; RoomID string }
type CreateGame struct { SessionID, RoomID, GameName string; RequestID uint64 }
type GameCreated struct { GameID, RoomID, Creator, Status string; RequestID uint64 }
type JoinGame struct { SessionID, GameID string; RequestID uint64 }
type GameJoined struct { GameID string; Participants []string; RequestID uint64 }
type SendRoomChat struct { SessionID, RoomID, Body string; RequestID uint64 }
type RoomChat struct { RoomID, Sender, Body string; TimeMS int64; RequestID uint64 }
type SendGameChat struct { SessionID, GameID, Body string; RequestID uint64 }
type GameChat struct { GameID, Sender, Body string; TimeMS int64; RequestID uint64 }
type RequestRejected struct { RequestID uint64; Code, Task, ScopeID string }
type GameListed struct { GameID, Creator, Status string }

type clock func() time.Time
type room struct { id string; members map[string]bool; games map[string]*game; chat []RoomChat }
type game struct { id, roomID, creator, name, status string; members map[string]bool; chat []GameChat }
type cachedResult struct { fingerprint string; response any }

type ServerCore struct {
	mu sync.RWMutex
	opMu sync.Mutex
	clock clock
	seq atomic.Uint64
	sessions map[string]string
	rooms map[string]*room
	cache map[string]map[string]cachedResult
}

func NewServer() *ServerCore {
	s := &ServerCore{clock: time.Now, sessions: make(map[string]string), rooms: make(map[string]*room), cache: make(map[string]map[string]cachedResult)}
	s.rooms["lobby"] = &room{id: "lobby", members: make(map[string]bool), games: make(map[string]*game)}
	return s
}

func (s *ServerCore) IssueSession(identity string) (string, error) {
	if identity == "" || !utf8.ValidString(identity) { return "", errors.New("invalid identity") }
	token := s.newID("sess")
	s.mu.Lock(); s.sessions[token] = identity; s.mu.Unlock()
	return token, nil
}

func (s *ServerCore) AddRoom(roomID string) error {
	if !validName(roomID) { return errors.New("invalid room id") }
	s.mu.Lock(); defer s.mu.Unlock()
	if _, ok := s.rooms[roomID]; ok { return errors.New("room exists") }
	s.rooms[roomID] = &room{id: roomID, members: make(map[string]bool), games: make(map[string]*game)}
	return nil
}

func (s *ServerCore) Handle(request any) any {
	switch r := request.(type) {
	case ListRooms: return s.listRooms(r)
	case EnterRoom: return s.enterRoom(r)
	case ListGames: return s.listGames(r)
	case CreateGame: return s.createGame(r)
	case JoinGame: return s.joinGame(r)
	case SendRoomChat: return s.sendRoomChat(r)
	case SendGameChat: return s.sendGameChat(r)
	default: return RequestRejected{Code: "unsupported_request", Task: "unknown", ScopeID: ""}
	}
}

func (s *ServerCore) listRooms(r ListRooms) any {
	return s.cached(r.SessionID, "list_rooms", r.RequestID, r, func(identity string) any {
		s.mu.RLock(); defer s.mu.RUnlock(); ids := make([]string, 0, len(s.rooms)); for id := range s.rooms { ids = append(ids, id) }; sortStrings(ids)
		return RoomsListed{RoomIDs: ids, RequestID: r.RequestID}
	})
}

func (s *ServerCore) enterRoom(r EnterRoom) any {
	return s.cached(r.SessionID, "enter_room", r.RequestID, r, func(identity string) any {
		s.mu.Lock(); defer s.mu.Unlock(); rm, ok := s.rooms[r.RoomID]; if !ok { return reject(r.RequestID, "not_found", "enter_room") }; rm.members[identity] = true
		return RoomEntered{RoomID: rm.id, GameIDs: gameIDs(rm), RequestID: r.RequestID}
	})
}

func (s *ServerCore) listGames(r ListGames) any {
	return s.cached(r.SessionID, "list_games", r.RequestID, r, func(identity string) any {
		s.mu.RLock(); defer s.mu.RUnlock(); rm, ok := s.rooms[r.RoomID]; if !ok || !rm.members[identity] { return reject(r.RequestID, "forbidden", "list_games") }
		games := make([]GameListed, 0, len(rm.games)); for _, g := range rm.games { games = append(games, GameListed{GameID:g.id, Creator:g.creator, Status:g.status}) }; sortGameListings(games)
		return GamesListed{Games: games, RoomID: rm.id, RequestID: r.RequestID}
	})
}

func (s *ServerCore) createGame(r CreateGame) any {
	return s.cached(r.SessionID, "create_game", r.RequestID, r, func(identity string) any {
		if !validName(r.GameName) { return reject(r.RequestID, "invalid_name", "create_game") }
		s.mu.Lock(); defer s.mu.Unlock(); rm, ok := s.rooms[r.RoomID]; if !ok || !rm.members[identity] { return reject(r.RequestID, "forbidden", "create_game") }
		id := s.newID("game"); rm.games[id] = &game{id:id, roomID:rm.id, creator:identity, name:r.GameName, status:"open", members:map[string]bool{identity:true}}
		return GameCreated{GameID:id, RoomID:rm.id, Creator:identity, Status:"open", RequestID:r.RequestID}
	})
}

func (s *ServerCore) joinGame(r JoinGame) any {
	return s.cached(r.SessionID, "join_game", r.RequestID, r, func(identity string) any {
		s.mu.Lock(); defer s.mu.Unlock(); g, rm := s.findGame(r.GameID); if g == nil || rm == nil || !rm.members[identity] { return reject(r.RequestID, "forbidden", "join_game") }; g.members[identity] = true
		participants := make([]string, 0, len(g.members)); for p := range g.members { participants = append(participants, p) }; sortStrings(participants)
		return GameJoined{GameID:g.id, Participants:participants, RequestID:r.RequestID}
	})
}

func (s *ServerCore) sendRoomChat(r SendRoomChat) any {
	return s.cached(r.SessionID, "room_chat", r.RequestID, r, func(identity string) any {
		if !validChat(r.Body) { return reject(r.RequestID, "invalid_body", "room_chat") }
		s.mu.Lock(); defer s.mu.Unlock(); rm, ok := s.rooms[r.RoomID]; if !ok || !rm.members[identity] { return reject(r.RequestID, "forbidden", "room_chat") }
		msg := RoomChat{RoomID:rm.id, Sender:identity, Body:r.Body, TimeMS:s.clock().UnixMilli(), RequestID:r.RequestID}; rm.chat = appendBoundedRoom(rm.chat, msg); return msg
	})
}

func (s *ServerCore) sendGameChat(r SendGameChat) any {
	return s.cached(r.SessionID, "game_chat", r.RequestID, r, func(identity string) any {
		if !validChat(r.Body) { return reject(r.RequestID, "invalid_body", "game_chat") }
		s.mu.Lock(); defer s.mu.Unlock(); g, _ := s.findGame(r.GameID); if g == nil || !g.members[identity] { return reject(r.RequestID, "forbidden", "game_chat") }
		msg := GameChat{GameID:g.id, Sender:identity, Body:r.Body, TimeMS:s.clock().UnixMilli(), RequestID:r.RequestID}; g.chat = appendBoundedGame(g.chat, msg); return msg
	})
}

func (s *ServerCore) cached(session, task string, requestID uint64, request any, action func(string) any) any {
	if requestID == 0 { return reject(0, "invalid_request_id", task) }
	s.mu.RLock(); identity, authenticated := s.sessions[session]; s.mu.RUnlock(); if !authenticated { return reject(requestID, "unauthorized", task) }
	fingerprint := fingerprint(request); key := task + ":" + fmt.Sprint(requestID)
	s.opMu.Lock(); defer s.opMu.Unlock()
	s.mu.Lock(); if s.cache[session] == nil { s.cache[session] = make(map[string]cachedResult) }; if old, ok := s.cache[session][key]; ok { s.mu.Unlock(); if old.fingerprint == fingerprint { return old.response }; return reject(requestID, "request_id_conflict", task) }; s.mu.Unlock()
	response := action(identity)
	s.mu.Lock(); s.cache[session][key] = cachedResult{fingerprint:fingerprint, response:response}; s.mu.Unlock(); return response
}

func (s *ServerCore) findGame(id string) (*game, *room) { for _, rm := range s.rooms { if g, ok := rm.games[id]; ok { return g, rm } }; return nil, nil }
func (s *ServerCore) newID(prefix string) string { n := s.seq.Add(1); return fmt.Sprintf("%s-%d", prefix, n) }
func reject(id uint64, code, task string) RequestRejected { return RequestRejected{RequestID:id, Code:code, Task:task} }
func validName(v string) bool { return v != "" && utf8.ValidString(v) && utf8.RuneCountInString(v) <= MaxNameRunes }
func validChat(v string) bool { return v != "" && utf8.ValidString(v) && utf8.RuneCountInString(v) <= MaxChatRunes }
func gameIDs(r *room) []string { ids:=make([]string,0,len(r.games)); for id:=range r.games { ids=append(ids,id) }; sortStrings(ids); return ids }
func appendBoundedRoom(v []RoomChat, x RoomChat) []RoomChat { v=append(v,x); if len(v)>MaxChatEntries { v=v[len(v)-MaxChatEntries:] }; return v }
func appendBoundedGame(v []GameChat, x GameChat) []GameChat { v=append(v,x); if len(v)>MaxChatEntries { v=v[len(v)-MaxChatEntries:] }; return v }
func fingerprint(v any) string { b,_:=json.Marshal(v); h:=sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func sortStrings(v []string) { for i:=1;i<len(v);i++ { for j:=i;j>0 && v[j]<v[j-1];j-- { v[j],v[j-1]=v[j-1],v[j] } } }
func sortGameListings(v []GameListed) { for i:=1;i<len(v);i++ { for j:=i;j>0 && strings.Compare(v[j].GameID,v[j-1].GameID)<0;j-- { v[j],v[j-1]=v[j-1],v[j] } } }
