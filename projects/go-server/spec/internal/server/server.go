package server

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"github.com/gorilla/websocket"
)

// NewHTTPServer returns a lightweight HTTP server wrapper exposing HandleWS.
func NewHTTPServer() *HTTPServer {
	return &HTTPServer{}
}

type HTTPServer struct{}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

const (
	// Expected WebSocket subprotocol token. Using a standard Sec-WebSocket-Protocol
	// selection lets proxies and Kubernetes tunnels accept the upgrade while
	// still allowing us to carry a binary protobuf frame protocol over WS.
	SubprotocolToken = "leanfm.v1+proto"
)

// HandleWS upgrades the connection and echoes received messages as JSON or
// binary frames depending on the client. It requires the Sec-WebSocket-Protocol
// token so proxies and tunnels will accept the upgrade.
func (s *HTTPServer) HandleWS(w http.ResponseWriter, r *http.Request) {
	// Require the agreed subprotocol token from clients so proxies/tunnels will
	// accept the upgrade. If the client didn't request it, reject the upgrade
	// with a clear message.
	reqProto := r.Header.Get("Sec-WebSocket-Protocol")
	if !strings.Contains(reqProto, SubprotocolToken) {
		http.Error(w, "client must request subprotocol: "+SubprotocolToken, http.StatusBadRequest)
		return
	}

	respHeader := http.Header{}
	respHeader.Add("Sec-WebSocket-Protocol", SubprotocolToken)
	c, err := upgrader.Upgrade(w, r, respHeader)
	if err != nil {
		log.Printf("upgrade error: %v", err)
		return
	}
	defer c.Close()

	log.Printf("ws connected subprotocol=%s", c.Subprotocol())

	for {
		mt, msg, err := c.ReadMessage()
		if err != nil {
			log.Printf("read error: %v", err)
			return
		}

		// If this is a binary frame (expected protobuf), echo it back as binary.
		if mt == websocket.BinaryMessage {
			if err := c.WriteMessage(websocket.BinaryMessage, msg); err != nil {
				log.Printf("write error: %v", err)
				return
			}
			continue
		}

		// For text frames, try to parse JSON and echo as JSON (convenient for
		// browser-based debugging). Otherwise, just echo the raw text.
		var m map[string]interface{}
		if err := json.Unmarshal(msg, &m); err != nil {
			if err := c.WriteMessage(websocket.TextMessage, msg); err != nil {
				log.Printf("write error: %v", err)
				return
			}
			continue
		}

		if err := c.WriteJSON(map[string]interface{}{"echo": m}); err != nil {
			log.Printf("write error: %v", err)
			return
		}
	}
}
