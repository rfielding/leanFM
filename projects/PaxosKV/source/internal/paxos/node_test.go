package paxos

import (
	"context"
	"fmt"
	"leanfm/paxoskv/internal/protocol"
	"leanfm/paxoskv/internal/trace"
	"net"
	"sync"
	"testing"
	"time"
)

func freeAddr(t *testing.T) string {
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	a := l.Addr().String()
	l.Close()
	return a
}

type cluster struct {
	nodes  []*Node
	cancel context.CancelFunc
	dirs   []string
	peers  map[string]string
}

func startCluster(t *testing.T, dirs []string, peers map[string]string) *cluster {
	ctx, cancel := context.WithCancel(context.Background())
	c := &cluster{cancel: cancel, dirs: dirs, peers: peers}
	for i := 0; i < 3; i++ {
		id := fmt.Sprintf("kv-%d", i)
		n, e := NewNode(id, peers[id], dirs[i], peers, &trace.Sink{})
		if e != nil {
			t.Fatal(e)
		}
		c.nodes = append(c.nodes, n)
		go func() { _ = n.Serve(ctx) }()
	}
	deadline := time.Now().Add(2 * time.Second)
	for _, a := range peers {
		for {
			conn, e := net.DialTimeout("tcp", a, 20*time.Millisecond)
			if e == nil {
				conn.Close()
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("replica %s did not start", a)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	return c
}
func newCluster(t *testing.T) *cluster {
	peers := map[string]string{}
	dirs := []string{t.TempDir(), t.TempDir(), t.TempDir()}
	for i := 0; i < 3; i++ {
		peers[fmt.Sprintf("kv-%d", i)] = freeAddr(t)
	}
	return startCluster(t, dirs, peers)
}
func (c *cluster) stop() {
	c.cancel()
	for _, n := range c.nodes {
		n.Close()
	}
	time.Sleep(30 * time.Millisecond)
}
func TestTwoConcurrentSessionsConverge(t *testing.T) {
	c := newCluster(t)
	defer c.stop()
	addrs := c.nodes[0].addresses()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, e := ClientPut(ctx, addrs, fmt.Sprintf("s%d", i), fmt.Sprintf("r%d", i), fmt.Sprintf("k%d", i), fmt.Sprintf("v%d", i))
			errs <- e
		}(i)
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	r, e := ClientList(ctx, addrs, "s0", "list")
	if e != nil {
		t.Fatal(e)
	}
	if len(r.Entries) != 2 {
		t.Fatalf("want 2 entries, got %#v", r.Entries)
	}
}
func TestLastCommittedSlotWins(t *testing.T) {
	c := newCluster(t)
	defer c.stop()
	a := c.nodes[0].addresses()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	r1, e := ClientPut(ctx, a, "s1", "r1", "same", "first")
	if e != nil {
		t.Fatal(e)
	}
	r2, e := ClientPut(ctx, a, "s2", "r2", "same", "second")
	if e != nil {
		t.Fatal(e)
	}
	if r2.Slot <= r1.Slot {
		t.Fatalf("slots not increasing: %d %d", r1.Slot, r2.Slot)
	}
	if len(r2.Entries) != 1 || r2.Entries[0].Value != "second" {
		t.Fatalf("last slot did not win: %#v", r2.Entries)
	}
	retry, e := ClientPut(ctx, a, "s2", "r2", "same", "second")
	if e != nil {
		t.Fatal(e)
	}
	if retry.Slot != r2.Slot {
		t.Fatalf("idempotent retry allocated slot %d after %d", retry.Slot, r2.Slot)
	}
}
func TestOneDownStillWritesAndAllDownRecovers(t *testing.T) {
	c := newCluster(t)
	a := c.nodes[0].addresses()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, e := ClientPut(ctx, a, "s", "r1", "before", "shutdown"); e != nil {
		t.Fatal(e)
	}
	c.nodes[2].listener.Close()
	c.nodes[2].Store.Close()
	if _, e := ClientPut(ctx, a[:2], "s", "r2", "while", "two-up"); e != nil {
		t.Fatal(e)
	}
	dirs, peers := c.dirs, c.peers
	c.stop()
	c2 := startCluster(t, dirs, peers)
	defer c2.stop()
	r, e := ClientList(ctx, c2.nodes[0].addresses(), "s", "after-restart")
	if e != nil {
		t.Fatal(e)
	}
	m := map[string]string{}
	for _, x := range r.Entries {
		m[x.Key] = x.Value
	}
	if m["before"] != "shutdown" || m["while"] != "two-up" {
		t.Fatalf("full shutdown lost acknowledged data: %#v", m)
	}
}

func TestAbandonedPrepareDoesNotLeaveLogGap(t *testing.T) {
	c := newCluster(t)
	defer c.stop()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	for _, addr := range c.nodes[0].addresses() {
		if _, e := call(ctx, addr, protocol.Envelope{Type: "prepare", Slot: 1, BallotCounter: 99, BallotNode: "abandoned"}); e != nil {
			t.Fatal(e)
		}
	}
	r, e := ClientPut(ctx, c.nodes[0].addresses(), "s", "after-abandoned", "key", "value")
	if e != nil {
		t.Fatal(e)
	}
	if r.Slot != 1 {
		t.Fatalf("abandoned prepare left a gap; committed slot %d", r.Slot)
	}
}
