// requirement:proof:durable quorum -- accepted state is fsynced before acknowledgment.
package paxos

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

type Ballot struct {
	Counter uint64 `json:"counter"`
	Node    string `json:"node"`
}

func (b Ballot) Less(o Ballot) bool {
	return b.Counter < o.Counter || (b.Counter == o.Counter && b.Node < o.Node)
}
func (b Ballot) Equal(o Ballot) bool { return b.Counter == o.Counter && b.Node == o.Node }

type Value struct {
	Key       string `json:"key"`
	Value     string `json:"value"`
	RequestID string `json:"request_id"`
}
type Slot struct {
	Promised    Ballot `json:"promised"`
	Accepted    Ballot `json:"accepted"`
	Value       Value  `json:"value"`
	HasAccepted bool   `json:"has_accepted"`
	Committed   bool   `json:"committed"`
}
type walRecord struct {
	Kind   string `json:"kind"`
	Slot   uint64 `json:"slot"`
	Ballot Ballot `json:"ballot"`
	Value  Value  `json:"value"`
}

type Store struct {
	mu    sync.Mutex
	path  string
	file  *os.File
	slots map[uint64]Slot
}

func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "accepted.wal")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	s := &Store{path: path, file: f, slots: map[uint64]Slot{}}
	if err = s.recover(); err != nil {
		f.Close()
		return nil, err
	}
	if _, err = f.Seek(0, io.SeekEnd); err != nil {
		f.Close()
		return nil, err
	}
	return s, nil
}
func (s *Store) recover() error {
	if _, err := s.file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	r := bufio.NewReader(s.file)
	var good int64
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			var rec walRecord
			if e := json.Unmarshal(line[:len(line)-1], &rec); e != nil {
				return fmt.Errorf("corrupt durable record at %d: %w", good, e)
			}
			s.apply(rec)
			good += int64(len(line))
			if err == nil {
				continue
			}
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
	}
	st, err := s.file.Stat()
	if err != nil {
		return err
	}
	if st.Size() != good {
		if err = s.file.Truncate(good); err != nil {
			return err
		}
		if err = s.file.Sync(); err != nil {
			return err
		}
	}
	return nil
}
func (s *Store) apply(r walRecord) {
	x := s.slots[r.Slot]
	switch r.Kind {
	case "promise":
		if x.Promised.Less(r.Ballot) {
			x.Promised = r.Ballot
		}
	case "accept":
		x.Promised = r.Ballot
		x.Accepted = r.Ballot
		x.Value = r.Value
		x.HasAccepted = true
	case "commit":
		x.Value = r.Value
		x.Committed = true
	}
	s.slots[r.Slot] = x
}
func (s *Store) append(rec walRecord) error {
	b, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if _, err = s.file.Write(b); err != nil {
		return err
	}
	if err = s.file.Sync(); err != nil {
		return err
	}
	s.apply(rec)
	return nil
}
func (s *Store) Promise(slot uint64, b Ballot) (Slot, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	x := s.slots[slot]
	if b.Less(x.Promised) {
		return x, false, nil
	}
	if x.Promised.Equal(b) {
		return x, true, nil
	}
	if err := s.append(walRecord{Kind: "promise", Slot: slot, Ballot: b}); err != nil {
		return x, false, err
	}
	return s.slots[slot], true, nil
}
func (s *Store) Accept(slot uint64, b Ballot, v Value) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	x := s.slots[slot]
	if b.Less(x.Promised) {
		return false, nil
	}
	if x.HasAccepted && x.Accepted.Equal(b) && (x.Value != v) {
		return false, errors.New("conflicting value for ballot and slot")
	}
	if err := s.append(walRecord{Kind: "accept", Slot: slot, Ballot: b, Value: v}); err != nil {
		return false, err
	}
	return true, nil
}
func (s *Store) Commit(slot uint64, v Value) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	x := s.slots[slot]
	if x.Committed && x.Value != v {
		return errors.New("conflicting committed value")
	}
	return s.append(walRecord{Kind: "commit", Slot: slot, Value: v})
}
func (s *Store) Snapshot() map[uint64]Slot {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[uint64]Slot, len(s.slots))
	for k, v := range s.slots {
		out[k] = v
	}
	return out
}
func (s *Store) Entries() (map[string]string, uint64) {
	slots := s.Snapshot()
	ids := make([]int, 0, len(slots))
	for id, x := range slots {
		if x.Committed {
			ids = append(ids, int(id))
		}
	}
	sort.Ints(ids)
	m := map[string]string{}
	var max uint64
	for _, id := range ids {
		x := slots[uint64(id)]
		m[x.Value.Key] = x.Value.Value
		if uint64(id) > max {
			max = uint64(id)
		}
	}
	return m, max
}
func (s *Store) FindCommittedRequest(requestID string) (uint64, bool) {
	slots := s.Snapshot()
	for id, x := range slots {
		if x.Committed && x.Value.RequestID == requestID {
			return id, true
		}
	}
	return 0, false
}
func (s *Store) Close() error { s.mu.Lock(); defer s.mu.Unlock(); return s.file.Close() }
