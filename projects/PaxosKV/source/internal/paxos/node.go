// requirement:grammar:quorum_write -- classic Paxos over three durable homogeneous replicas.
package paxos

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sort"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"leanfm/paxoskv/internal/protocol"
	"leanfm/paxoskv/internal/trace"
)

const Quorum = 2

type Node struct {
	ID, Addr string
	Peers    map[string]string
	Store    *Store
	Trace    *trace.Sink
	counter  atomic.Uint64
	listener net.Listener
}

func NewNode(id, addr, dir string, peers map[string]string, tr *trace.Sink) (*Node, error) {
	s, e := OpenStore(dir)
	if e != nil {
		return nil, e
	}
	n := &Node{ID: id, Addr: addr, Peers: peers, Store: s, Trace: tr}
	n.counter.Store(uint64(time.Now().UnixNano()))
	return n, nil
}
func (n *Node) nextBallot() Ballot      { return Ballot{Counter: n.counter.Add(1), Node: n.ID} }
func ballot(e protocol.Envelope) Ballot { return Ballot{Counter: e.BallotCounter, Node: e.BallotNode} }
func envBallot(t string, b Ballot, slot uint64) protocol.Envelope {
	return protocol.Envelope{Type: t, BallotCounter: b.Counter, BallotNode: b.Node, Slot: slot}
}

func (n *Node) Serve(ctx context.Context) error {
	ln, e := net.Listen("tcp", n.Addr)
	if e != nil {
		return e
	}
	n.listener = ln
	go func() { <-ctx.Done(); ln.Close() }()
	for {
		c, e := ln.Accept()
		if e != nil {
			if ctx.Err() != nil || errors.Is(e, net.ErrClosed) {
				return nil
			}
			continue
		}
		go n.handleConn(c)
	}
}
func (n *Node) Close() error {
	if n.listener != nil {
		n.listener.Close()
	}
	return n.Store.Close()
}
func (n *Node) handleConn(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	req, e := protocol.ReadFrame(c)
	if e != nil {
		return
	}
	resp := n.handle(req)
	_ = protocol.WriteFrame(c, resp)
}
func (n *Node) handle(req protocol.Envelope) protocol.Envelope {
	switch req.Type {
	case "prepare":
		x, ok, e := n.Store.Promise(req.Slot, ballot(req))
		r := protocol.Envelope{Type: "promise", Success: ok, Slot: req.Slot, BallotCounter: x.Promised.Counter, BallotNode: x.Promised.Node}
		if e != nil {
			r.Error = e.Error()
		}
		if x.HasAccepted {
			r.AcceptedBallotCounter = x.Accepted.Counter
			r.AcceptedBallotNode = x.Accepted.Node
			r.Key = x.Value.Key
			r.Value = x.Value.Value
			r.RequestID = x.Value.RequestID
		}
		r.Committed = x.Committed
		return r
	case "accept":
		ok, e := n.Store.Accept(req.Slot, ballot(req), Value{Key: req.Key, Value: req.Value, RequestID: req.RequestID})
		r := protocol.Envelope{Type: "accepted", Success: ok, Slot: req.Slot}
		if e != nil {
			r.Error = e.Error()
		}
		return r
	case "commit":
		e := n.Store.Commit(req.Slot, Value{Key: req.Key, Value: req.Value, RequestID: req.RequestID})
		r := protocol.Envelope{Type: "committed", Success: e == nil, Slot: req.Slot}
		if e != nil {
			r.Error = e.Error()
		}
		return r
	case "status":
		return n.statusEnvelope()
	case "client_put":
		entries, slot, e := n.Put(context.Background(), req.Session, req.RequestID, req.Key, req.Value)
		return result("client_put_result", entries, slot, e)
	case "client_list":
		entries, slot, e := n.List(context.Background(), req.Session, req.RequestID)
		return result("client_list_result", entries, slot, e)
	default:
		return protocol.Envelope{Type: "error", Error: "unknown message type"}
	}
}
func result(kind string, m map[string]string, slot uint64, e error) protocol.Envelope {
	r := protocol.Envelope{Type: kind, Success: e == nil, Slot: slot}
	if e != nil {
		r.Error = e.Error()
		return r
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		r.Entries = append(r.Entries, protocol.Entry{Key: k, Value: m[k]})
	}
	return r
}
func (n *Node) statusEnvelope() protocol.Envelope {
	r := protocol.Envelope{Type: "status_result", Success: true}
	for id, x := range n.Store.Snapshot() {
		r.Slots = append(r.Slots, protocol.SlotState{Slot: id, PromisedCounter: x.Promised.Counter, PromisedNode: x.Promised.Node, AcceptedCounter: x.Accepted.Counter, AcceptedNode: x.Accepted.Node, Key: x.Value.Key, Value: x.Value.Value, RequestID: x.Value.RequestID, Committed: x.Committed})
	}
	sort.Slice(r.Slots, func(i, j int) bool { return r.Slots[i].Slot < r.Slots[j].Slot })
	return r
}

func call(ctx context.Context, addr string, req protocol.Envelope) (protocol.Envelope, error) {
	d := net.Dialer{Timeout: 750 * time.Millisecond}
	c, e := d.DialContext(ctx, "tcp", addr)
	if e != nil {
		return protocol.Envelope{}, e
	}
	defer c.Close()
	deadline := time.Now().Add(2 * time.Second)
	c.SetDeadline(deadline)
	if e = protocol.WriteFrame(c, req); e != nil {
		return protocol.Envelope{}, e
	}
	return protocol.ReadFrame(c)
}
func (n *Node) addresses() []string {
	a := make([]string, 0, len(n.Peers))
	for _, v := range n.Peers {
		a = append(a, v)
	}
	sort.Strings(a)
	return a
}
func (n *Node) collect(ctx context.Context, req protocol.Envelope) []protocol.Envelope {
	type rr struct {
		r protocol.Envelope
		e error
	}
	ch := make(chan rr, len(n.Peers))
	for _, a := range n.addresses() {
		go func(addr string) { r, e := call(ctx, addr, req); ch <- rr{r, e} }(a)
	}
	out := []protocol.Envelope{}
	for range n.Peers {
		x := <-ch
		if x.e == nil {
			out = append(out, x.r)
		}
	}
	return out
}

func (n *Node) choose(ctx context.Context, slot uint64, want Value) (Value, error) {
	var b Ballot
	var ok []protocol.Envelope
	for attempt := 0; attempt < 5; attempt++ {
		b = n.nextBallot()
		promises := n.collect(ctx, envBallot("prepare", b, slot))
		ok = ok[:0]
		var highest uint64
		for _, p := range promises {
			if p.BallotCounter > highest {
				highest = p.BallotCounter
			}
			if p.Success {
				ok = append(ok, p)
			}
		}
		if len(ok) >= Quorum {
			break
		}
		for current := n.counter.Load(); current <= highest; current = n.counter.Load() {
			if n.counter.CompareAndSwap(current, highest) {
				break
			}
		}
	}
	if len(ok) < Quorum {
		return Value{}, errors.New("no prepare quorum")
	}
	chosen := want
	var high Ballot
	for _, p := range ok {
		ab := Ballot{Counter: p.AcceptedBallotCounter, Node: p.AcceptedBallotNode}
		if p.AcceptedBallotCounter > 0 && (high.Less(ab) || high.Equal(Ballot{})) {
			high = ab
			chosen = Value{Key: p.Key, Value: p.Value, RequestID: p.RequestID}
		}
	}
	req := envBallot("accept", b, slot)
	req.Key, req.Value, req.RequestID = chosen.Key, chosen.Value, chosen.RequestID
	accepted := n.collect(ctx, req)
	count := 0
	for _, a := range accepted {
		if a.Success {
			count++
		}
	}
	if count < Quorum {
		return Value{}, errors.New("no durable accept quorum")
	}
	commit := protocol.Envelope{Type: "commit", Slot: slot, Key: chosen.Key, Value: chosen.Value, RequestID: chosen.RequestID}
	committed := n.collect(ctx, commit)
	commits := 0
	for _, c := range committed {
		if c.Success {
			commits++
		}
	}
	if commits < Quorum {
		return Value{}, errors.New("chosen value could not be durably committed on quorum")
	}
	return chosen, nil
}

func (n *Node) recover(ctx context.Context) (uint64, error) {
	statuses := n.collect(ctx, protocol.Envelope{Type: "status"})
	good := []protocol.Envelope{}
	for _, s := range statuses {
		if s.Success {
			good = append(good, s)
		}
	}
	if len(good) < Quorum {
		return 0, errors.New("no recovery quorum")
	}
	all := map[uint64][]protocol.SlotState{}
	var max uint64
	for _, s := range good {
		for _, x := range s.Slots {
			all[x.Slot] = append(all[x.Slot], x)
			if (x.AcceptedCounter > 0 || x.Committed) && x.Slot > max {
				max = x.Slot
			}
		}
	}
	for id := uint64(1); id <= max; id++ {
		xs := all[id]
		var selected *protocol.SlotState
		for i := range xs {
			x := &xs[i]
			if x.AcceptedCounter > 0 && (selected == nil || Ballot{Counter: selected.AcceptedCounter, Node: selected.AcceptedNode}.Less(Ballot{Counter: x.AcceptedCounter, Node: x.AcceptedNode})) {
				selected = x
			}
		}
		if selected == nil {
			continue
		}
		v := Value{Key: selected.Key, Value: selected.Value, RequestID: selected.RequestID}
		if _, e := n.choose(ctx, id, v); e != nil {
			return max, fmt.Errorf("recover slot %d: %w", id, e)
		}
	}
	return max, nil
}

func (n *Node) Put(ctx context.Context, session, requestID, key, value string) (map[string]string, uint64, error) {
	if !utf8.ValidString(key) || key == "" || len([]byte(key)) > 128 {
		return nil, 0, errors.New("key must contain 1..128 UTF-8 bytes")
	}
	if !utf8.ValidString(value) || len([]byte(value)) > 4096 {
		return nil, 0, errors.New("value exceeds 4096 UTF-8 bytes")
	}
	if requestID == "" {
		return nil, 0, errors.New("request_id is required")
	}
	for attempt := 0; attempt < 8; attempt++ {
		max, e := n.recover(ctx)
		if e != nil {
			return nil, 0, e
		}
		entries, _ := n.Store.Entries()
		if committedSlot, found := n.Store.FindCommittedRequest(requestID); found {
			return entries, committedSlot, nil
		}
		if _, exists := entries[key]; !exists && len(entries) >= 10000 {
			return nil, 0, errors.New("database key capacity reached")
		}
		slot := max + 1
		want := Value{Key: key, Value: value, RequestID: requestID}
		got, e := n.choose(ctx, slot, want)
		if e != nil {
			continue
		}
		if got.RequestID == requestID {
			m, _ := n.Store.Entries()
			n.Trace.Emit(trace.Event{Session: session, Task: requestID, Src: n.ID, Dst: "WebApp", Message: "PutSucceeded", Fields: map[string]any{"slot": slot, "quorum": Quorum}})
			return m, slot, nil
		}
	}
	return nil, 0, errors.New("write contention retry limit reached")
}
func (n *Node) List(ctx context.Context, session, requestID string) (map[string]string, uint64, error) {
	if _, e := n.recover(ctx); e != nil {
		return nil, 0, e
	}
	m, slot := n.Store.Entries()
	n.Trace.Emit(trace.Event{Session: session, Task: requestID, Src: n.ID, Dst: "WebApp", Message: "ListSucceeded", Fields: map[string]any{"committed_slot": slot}})
	return m, slot, nil
}

func ClientPut(ctx context.Context, replicas []string, session, requestID, key, value string) (protocol.Envelope, error) {
	return clientCall(ctx, replicas, protocol.Envelope{Type: "client_put", Session: session, RequestID: requestID, Key: key, Value: value})
}
func ClientList(ctx context.Context, replicas []string, session, requestID string) (protocol.Envelope, error) {
	return clientCall(ctx, replicas, protocol.Envelope{Type: "client_list", Session: session, RequestID: requestID})
}
func clientCall(ctx context.Context, replicas []string, req protocol.Envelope) (protocol.Envelope, error) {
	var last error
	for _, a := range replicas {
		r, e := call(ctx, a, req)
		if e == nil && r.Success {
			return r, nil
		}
		if e != nil {
			last = e
		} else {
			last = errors.New(r.Error)
		}
	}
	if last == nil {
		last = errors.New("no replicas configured")
	}
	return protocol.Envelope{}, last
}
