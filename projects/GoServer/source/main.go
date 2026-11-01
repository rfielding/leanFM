package goserver

import "fmt"

// DemoRun provides a small programmatic demo of the ServerCore API. It is
// intentionally not a main function so it can live in the goserver package
// without creating a separate package in the source directory.
func DemoRun() error {
	s := NewServer()
	_ = s.AddRoom("room1")

	sess, err := s.IssueSession("alice")
	if err != nil {
		return err
	}

	p := PersonHandler{Server: s, SessionID: sess}

	// Example sequence (errors are returned as RequestRejected values).
	fmt.Printf("ListRooms -> %#v\n", p.Send(ListRooms{SessionID: sess, RequestID: 1}))
	fmt.Printf("EnterRoom -> %#v\n", p.Send(EnterRoom{SessionID: sess, RoomID: "lobby", RequestID: 2}))
	fmt.Printf("CreateGame -> %#v\n", p.Send(CreateGame{SessionID: sess, RoomID: "lobby", GameName: "demo-game", RequestID: 3}))
	fmt.Printf("ListGames -> %#v\n", p.Send(ListGames{RoomID: "lobby", SessionID: sess, RequestID: 4}))
	fmt.Printf("SendRoomChat -> %#v\n", p.Send(SendRoomChat{SessionID: sess, RoomID: "lobby", Body: "hello room", RequestID: 7}))
	return nil
}
