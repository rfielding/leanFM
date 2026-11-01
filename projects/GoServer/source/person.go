package goserver

// PersonHandler is the small client-side adapter represented by the Person actor
// in the implementation mapping. It never supplies sender identity; the server
// derives that identity from SessionID.
type PersonHandler struct {
	Server    *ServerCore
	SessionID string
}

func (p PersonHandler) Send(request any) any {
	return p.Server.Handle(request)
}
