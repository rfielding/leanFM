package paxos

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDurableAcceptedAndCommittedSurviveRestart(t *testing.T) {
	dir := t.TempDir()
	s, e := OpenStore(dir)
	if e != nil {
		t.Fatal(e)
	}
	b := Ballot{1, "kv-0"}
	v := Value{"key", "value", "request"}
	if ok, e := s.Accept(1, b, v); e != nil || !ok {
		t.Fatalf("accept %v %v", ok, e)
	}
	if e = s.Commit(1, v); e != nil {
		t.Fatal(e)
	}
	s.Close()
	s, e = OpenStore(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	m, slot := s.Entries()
	if slot != 1 || m["key"] != "value" {
		t.Fatalf("lost durable state: %#v slot=%d", m, slot)
	}
}
func TestRecoveryTruncatesOnlyIncompleteFinalRecord(t *testing.T) {
	dir := t.TempDir()
	s, e := OpenStore(dir)
	if e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Promise(1, Ballot{1, "kv-0"}); e != nil {
		t.Fatal(e)
	}
	s.Close()
	p := filepath.Join(dir, "accepted.wal")
	f, e := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		t.Fatal(e)
	}
	f.WriteString("{partial")
	f.Close()
	s, e = OpenStore(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if got := s.Snapshot()[1].Promised; got.Counter != 1 {
		t.Fatalf("valid prefix lost: %#v", got)
	}
}
func TestRejectsConflictingSameBallotSlot(t *testing.T) {
	s, e := OpenStore(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	b := Ballot{1, "kv-0"}
	if ok, e := s.Accept(1, b, Value{"a", "1", "r1"}); e != nil || !ok {
		t.Fatal(ok, e)
	}
	if _, e = s.Accept(1, b, Value{"a", "2", "r2"}); e == nil {
		t.Fatal("conflicting acceptance succeeded")
	}
}
