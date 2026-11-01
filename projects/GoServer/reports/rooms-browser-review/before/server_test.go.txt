package goserver

import (
	"strings"
	"sync"
	"testing"
)

func setup(t *testing.T) (*ServerCore, string) {
	t.Helper(); s := NewServer(); token, err := s.IssueSession("alice"); if err != nil { t.Fatal(err) }; return s, token
}

func TestNavigationAndIsolatedChat(t *testing.T) {
	s, token := setup(t)
	if got := s.Handle(ListRooms{SessionID: token, RequestID: 1}).(RoomsListed); len(got.RoomIDs) != 1 || got.RoomIDs[0] != "lobby" { t.Fatalf("rooms: %#v", got) }
	if _, ok := s.Handle(EnterRoom{SessionID:token, RoomID:"lobby", RequestID:2}).(RoomEntered); !ok { t.Fatalf("enter failed") }
	created := s.Handle(CreateGame{SessionID:token, RoomID:"lobby", GameName:"friendly", RequestID:3}).(GameCreated)
	if _, ok := s.Handle(JoinGame{SessionID:token, GameID:created.GameID, RequestID:4}).(GameJoined); !ok { t.Fatalf("join failed") }
	room := s.Handle(SendRoomChat{SessionID:token, RoomID:"lobby", Body:"room", RequestID:5}).(RoomChat)
	game := s.Handle(SendGameChat{SessionID:token, GameID:created.GameID, Body:"game", RequestID:6}).(GameChat)
	if room.RoomID != "lobby" || game.GameID != created.GameID || room.Body == game.Body { t.Fatalf("chat crossed scope: %#v %#v", room, game) }
}

func TestAuthorizationAndServerIdentity(t *testing.T) {
	s, token := setup(t); other, _ := s.IssueSession("bob")
	s.Handle(EnterRoom{SessionID:token, RoomID:"lobby", RequestID:1})
	bad := s.Handle(SendRoomChat{SessionID:other, RoomID:"lobby", Body:"secret", RequestID:1}).(RequestRejected)
	if bad.Code != "forbidden" { t.Fatalf("expected forbidden, got %#v", bad) }
	if got := s.Handle(SendRoomChat{SessionID:token, RoomID:"lobby", Body:"hello", RequestID:2}).(RoomChat); got.Sender != "alice" { t.Fatalf("spoofable sender: %#v", got) }
}

func TestReplayConflictAndConcurrentCreateAreSafe(t *testing.T) {
	s, token := setup(t); s.Handle(EnterRoom{SessionID:token, RoomID:"lobby", RequestID:1})
	req := CreateGame{SessionID:token, RoomID:"lobby", GameName:"one", RequestID:2}
	first := s.Handle(req).(GameCreated); replay := s.Handle(req).(GameCreated)
	if first.GameID != replay.GameID { t.Fatalf("replay created twice: %#v %#v", first, replay) }
	conflict := s.Handle(CreateGame{SessionID:token, RoomID:"lobby", GameName:"two", RequestID:2}).(RequestRejected)
	if conflict.Code != "request_id_conflict" { t.Fatalf("expected conflict: %#v", conflict) }
	var wg sync.WaitGroup; results := make(chan any, 20)
	for i:=0; i<20; i++ { wg.Add(1); go func(){ defer wg.Done(); results <- s.Handle(CreateGame{SessionID:token, RoomID:"lobby", GameName:"concurrent", RequestID:99}) }() }
	wg.Wait(); close(results); id := ""; for result := range results { created, ok := result.(GameCreated); if !ok { t.Fatalf("concurrent result: %#v", result) }; if id == "" { id=created.GameID }; if id != created.GameID { t.Fatalf("different replay result: %#v", result) } }
}

func TestBoundsAndRetention(t *testing.T) {
	s, token := setup(t); s.Handle(EnterRoom{SessionID:token, RoomID:"lobby", RequestID:1})
	if got := s.Handle(CreateGame{SessionID:token, RoomID:"lobby", GameName:strings.Repeat("x", MaxNameRunes+1), RequestID:2}).(RequestRejected); got.Code != "invalid_name" { t.Fatalf("name bound: %#v", got) }
	if got := s.Handle(SendRoomChat{SessionID:token, RoomID:"lobby", Body:strings.Repeat("x", MaxChatRunes+1), RequestID:3}).(RequestRejected); got.Code != "invalid_body" { t.Fatalf("body bound: %#v", got) }
	for i:=0; i<MaxChatEntries+10; i++ { s.Handle(SendRoomChat{SessionID:token, RoomID:"lobby", Body:"x", RequestID:uint64(100+i)}) }
	s.mu.RLock(); defer s.mu.RUnlock(); if len(s.rooms["lobby"].chat) != MaxChatEntries { t.Fatalf("retention: %d", len(s.rooms["lobby"].chat)) }
}

func TestChannelBackpressureAndDrain(t *testing.T) {
	c := NewInprocessChannel(1); if err := c.Send("a"); err != nil { t.Fatal(err) }; if err := c.Send("b"); err != ErrChannelFull { t.Fatalf("full: %v", err) }
	c.Close(); if err := c.Send("c"); err != ErrChannelClosed { t.Fatalf("closed send: %v", err) }
	v, err := c.Receive(); if err != nil || v != "a" { t.Fatalf("drain: %v %#v", err, v) }
	if _, err := c.Receive(); err != ErrChannelClosed { t.Fatalf("closed receive: %v", err) }
}
