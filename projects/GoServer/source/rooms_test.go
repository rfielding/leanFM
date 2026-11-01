package goserver

// Requirement refs: grammar:create_room; proof:create_room never crosses authority or scope;
// property:create_room authorized correlated result; grammar:create_game.
import (
	"fmt"
	"strings"
	"sync"
	"testing"
)

func TestCreateRoomAuthorizationBoundsAndReplay(t *testing.T) {
	s, token := setup(t)
	count := len(s.rooms)
	for i, name := range []string{"", "  ", strings.Repeat("界", MaxNameRunes+1), string([]byte{255})} {
		result := s.Handle(CreateRoom{SessionID: token, RoomName: name, RequestID: uint64(i + 1)}).(RequestRejected)
		if result.Code != "invalid_name" || len(s.rooms) != count {
			t.Fatalf("invalid name mutated rooms: %#v", result)
		}
	}
	if result := s.Handle(CreateRoom{SessionID: "invalid", RoomName: "private", RequestID: 10}).(RequestRejected); result.Code != "unauthorized" {
		t.Fatal(result)
	}
	request := CreateRoom{SessionID: token, RoomName: "  Study group  ", RequestID: 11}
	first := s.Handle(request).(RoomCreated)
	if first.RoomID != "Study group" || first.RequestID != 11 {
		t.Fatal(first)
	}
	if result := s.Handle(request).(RoomCreated); result != first {
		t.Fatal(result)
	}
	if result := s.Handle(CreateRoom{SessionID: token, RoomName: "different", RequestID: 11}).(RequestRejected); result.Code != "request_id_conflict" {
		t.Fatal(result)
	}
	if _, err := s.RoomChatHistory(token, first.RoomID); err == nil {
		t.Fatal("creation implicitly granted membership")
	}
	if result := s.Handle(CreateRoom{SessionID: token, RoomName: "Study group", RequestID: 12}).(RequestRejected); result.Code != "room_exists" {
		t.Fatal(result)
	}
}
func TestConcurrentRoomCreationAndCapacity(t *testing.T) {
	s, token := setup(t)
	var wg sync.WaitGroup
	results := make(chan any, 25)
	for i := 0; i < 25; i++ {
		wg.Add(1)
		go func(id uint64) {
			defer wg.Done()
			results <- s.Handle(CreateRoom{SessionID: token, RoomName: "one room", RequestID: id})
		}(uint64(i + 1))
	}
	wg.Wait()
	close(results)
	winners := 0
	for result := range results {
		if _, ok := result.(RoomCreated); ok {
			winners++
		} else if result.(RequestRejected).Code != "room_exists" {
			t.Fatal(result)
		}
	}
	if winners != 1 {
		t.Fatalf("%d winners", winners)
	}
	for i := len(s.rooms); i < MaxRooms; i++ {
		if _, ok := s.Handle(CreateRoom{SessionID: token, RoomName: fmt.Sprintf("room-%d", i), RequestID: uint64(100 + i)}).(RoomCreated); !ok {
			t.Fatal("unexpected capacity failure")
		}
	}
	if result := s.Handle(CreateRoom{SessionID: token, RoomName: "overflow", RequestID: 200}).(RequestRejected); result.Code != "busy" || len(s.rooms) != MaxRooms {
		t.Fatal(result)
	}
}
func TestReplayRemainsSafeAfterAdmissionLimit(t *testing.T) {
	s, token := setup(t)
	request := CreateRoom{SessionID: token, RoomName: "first", RequestID: 1}
	first := s.Handle(request).(RoomCreated)
	for i := 0; i < MaxReplayEntries-1; i++ {
		s.Handle(EnterRoom{SessionID: token, RoomID: "lobby", RequestID: uint64(2 + i)})
	}
	if result := s.Handle(CreateRoom{SessionID: token, RoomName: "over budget", RequestID: 1000}).(RequestRejected); result.Code != "busy" {
		t.Fatal(result)
	}
	if result := s.Handle(request).(RoomCreated); result != first {
		t.Fatal("original result was evicted")
	}
	if result := s.Handle(ListRooms{SessionID: token, RequestID: 1001}).(RoomsListed); len(result.RoomIDs) != 2 {
		t.Fatal(result)
	}
}
func TestNamedChallengesAndChatHistoryStayInScope(t *testing.T) {
	s, token := setup(t)
	other, _ := s.IssueSession("bob")
	s.Handle(CreateRoom{SessionID: token, RoomName: "study", RequestID: 1})
	s.Handle(EnterRoom{SessionID: token, RoomID: "study", RequestID: 2})
	name := "<img src=x onerror=alert(1)>"
	created := s.Handle(CreateGame{SessionID: token, RoomID: "study", GameName: name, RequestID: 3}).(GameCreated)
	listed := s.Handle(ListGames{SessionID: token, RoomID: "study", RequestID: 4}).(GamesListed)
	if created.GameName != name || listed.Games[0].GameName != name {
		t.Fatal("challenge name lost")
	}
	s.Handle(SendRoomChat{SessionID: token, RoomID: "study", Body: "room only", RequestID: 5})
	s.Handle(SendGameChat{SessionID: token, GameID: created.GameID, Body: "game only", RequestID: 6})
	if _, err := s.RoomChatHistory(other, "study"); err == nil {
		t.Fatal("foreign room disclosure")
	}
	if _, _, err := s.GameChatHistory(other, created.GameID); err == nil {
		t.Fatal("foreign game disclosure")
	}
	room, _ := s.RoomChatHistory(token, "study")
	game, _, _ := s.GameChatHistory(token, created.GameID)
	if len(room) != 1 || room[0].Body != "room only" || len(game) != 1 || game[0].Body != "game only" {
		t.Fatal("chat crossed scopes")
	}
}
