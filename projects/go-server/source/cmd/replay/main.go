// R1/R2: batch oracle used by cross-language conformance, not a test substitute.
package main

import (
	"bufio"
	"encoding/json"
	"leanfm/goserver/game"
	"os"
)

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	out := json.NewEncoder(os.Stdout)
	for scanner.Scan() {
		var request struct {
			Size     int           `json:"size"`
			Players  int           `json:"players"`
			MaxTurns int           `json:"max_turns"`
			Actions  []game.Action `json:"actions"`
		}
		var failure string
		var states []game.Position
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			out.Encode(map[string]string{"error": "invalid JSON"})
			continue
		}
		s, err := game.New(request.Size, request.Players, request.MaxTurns)
		if err == nil {
			states = append(states, s)
			for _, a := range request.Actions {
				s, err = game.Apply(s, a)
				if err != nil {
					break
				}
				states = append(states, s)
			}
		}
		if err != nil {
			failure = err.Error()
		}
		if len(states) == 0 {
			out.Encode(map[string]string{"error": failure})
			continue
		}
		out.Encode(struct {
			States []game.Position `json:"states"`
			Score  game.Scores     `json:"score"`
			Error  string          `json:"error,omitempty"`
		}{states, game.Score(states[len(states)-1]), failure})
	}
}
