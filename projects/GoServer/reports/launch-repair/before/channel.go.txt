package goserver

import "sync"

// InprocessChannel is a bounded, closeable adapter for the selected in-process
// transport. Send never mutates the queue after a full or closed result.
type InprocessChannel struct {
	mu sync.Mutex
	queue chan any
	closed bool
}

func NewInprocessChannel(capacity int) *InprocessChannel {
	if capacity < 1 { capacity = 1 }
	return &InprocessChannel{queue: make(chan any, capacity)}
}

func (c *InprocessChannel) Send(v any) error {
	c.mu.Lock(); defer c.mu.Unlock()
	if c.closed { return ErrChannelClosed }
	select { case c.queue <- v: return nil; default: return ErrChannelFull }
}

func (c *InprocessChannel) Receive() (any, error) {
	v, ok := <-c.queue
	if ok { return v, nil }
	return nil, ErrChannelClosed
}

func (c *InprocessChannel) TryReceive() (any, bool, error) {
	select { case v, ok := <-c.queue: if !ok { return nil, false, ErrChannelClosed }; return v, true, nil; default: return nil, false, nil }
}

func (c *InprocessChannel) Close() {
	c.mu.Lock(); defer c.mu.Unlock()
	if !c.closed { c.closed = true; close(c.queue) }
}

type channelError string
func (e channelError) Error() string { return string(e) }
var ErrChannelClosed = channelError("channel closed")
var ErrChannelFull = channelError("channel full")
