// requirement:output:paxos.concurrent.order -- observable events retain partial-order provenance.
package trace

import (
	"encoding/json"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

type Event struct {
	ID      string         `json:"id"`
	Prior   []string       `json:"prior"`
	Session string         `json:"session"`
	Task    string         `json:"task"`
	Src     string         `json:"src"`
	Dst     string         `json:"dst"`
	TimeAt  int64          `json:"timeAt"`
	Message string         `json:"message"`
	Fields  map[string]any `json:"fields,omitempty"`
}
type Sink struct {
	mu   sync.Mutex
	file *os.File
	seq  atomic.Uint64
}

func Open(path string) (*Sink, error) {
	if path == "" {
		return &Sink{}, nil
	}
	f, e := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	return &Sink{file: f}, e
}
func (s *Sink) Emit(e Event) string {
	if e.ID == "" {
		e.ID = "e" + u64(s.seq.Add(1))
	}
	if e.TimeAt == 0 {
		e.TimeAt = time.Now().UnixNano()
	}
	if s.file != nil {
		s.mu.Lock()
		b, _ := json.Marshal(e)
		s.file.Write(append(b, '\n'))
		s.file.Sync()
		s.mu.Unlock()
	}
	return e.ID
}
func (s *Sink) Close() error {
	if s.file != nil {
		return s.file.Close()
	}
	return nil
}
func u64(v uint64) string {
	if v == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[i:])
}
