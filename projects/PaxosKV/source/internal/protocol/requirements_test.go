package protocol

import (
	"bytes"
	"reflect"
	"testing"
)

func TestEnvelopeRoundTrip(t *testing.T) {
	in := Envelope{Type: "accept", RequestID: "r1", BallotCounter: 7, BallotNode: "kv-1", Slot: 4, Key: "hello", Value: "world", Success: true, Entries: []Entry{{"a", "1"}}, Slots: []SlotState{{Slot: 4, AcceptedCounter: 7, AcceptedNode: "kv-1", Key: "hello", Value: "world", Committed: true, RequestID: "r1"}}}
	out, e := Unmarshal(in.Marshal())
	if e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(in, out) {
		t.Fatalf("round trip mismatch\n%#v\n%#v", in, out)
	}
	var framed bytes.Buffer
	if e = WriteFrame(&framed, in); e != nil {
		t.Fatal(e)
	}
	out, e = ReadFrame(&framed)
	if e != nil || !reflect.DeepEqual(in, out) {
		t.Fatalf("frame round trip: %#v %v", out, e)
	}
}
func TestRejectsTruncatedProtobuf(t *testing.T) {
	if _, e := Unmarshal([]byte{0x0a, 0x05, 'x'}); e == nil {
		t.Fatal("truncated field accepted")
	}
}
