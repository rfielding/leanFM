package goserver

import "sync"

// Requirement refs: goserver; accepted ImplementationSpec.channels.
// A full send waits for space; closing wakes all waiters without losing queued items.
type InprocessChannel struct {
	mu       sync.Mutex
	changed  *sync.Cond
	queue    []any
	capacity int
	closed   bool
}

func NewInprocessChannel(capacity int) *InprocessChannel {
	if capacity < 1 {
		capacity = 1
	}
	c := &InprocessChannel{capacity: capacity}
	c.changed = sync.NewCond(&c.mu)
	return c
}
func (c *InprocessChannel) Send(v any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	for !c.closed && len(c.queue) == c.capacity {
		c.changed.Wait()
	}
	if c.closed {
		return ErrChannelClosed
	}
	c.queue = append(c.queue, v)
	c.changed.Broadcast()
	return nil
}
func (c *InprocessChannel) Receive() (any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for !c.closed && len(c.queue) == 0 {
		c.changed.Wait()
	}
	if len(c.queue) == 0 {
		return nil, ErrChannelClosed
	}
	return c.pop(), nil
}
func (c *InprocessChannel) pop() any {
	v := c.queue[0]
	c.queue[0] = nil
	c.queue = c.queue[1:]
	c.changed.Broadcast()
	return v
}
func (c *InprocessChannel) TryReceive() (any, bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.queue) > 0 {
		return c.pop(), true, nil
	}
	if c.closed {
		return nil, false, ErrChannelClosed
	}
	return nil, false, nil
}
func (c *InprocessChannel) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	c.changed.Broadcast()
}

type channelError string

func (e channelError) Error() string { return string(e) }

var ErrChannelClosed = channelError("channel closed")

// Retained for source compatibility; full sends now block rather than return it.
var ErrChannelFull = channelError("channel full")
