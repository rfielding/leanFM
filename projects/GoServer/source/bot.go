package goserver

// Requirement refs: actor:Bot; task:bot_turn; proof:bots never exhaust the server;
// proof:bots never act outside their turn.

import (
	"runtime"
	"sync"
	"time"
)

// botJob is BotTurn: a private copy of the position, bound to a game and turn revision.
type botJob struct {
	gameID  string
	seq     uint64
	geom    *Geom
	state   *State
	budget  time.Duration // hard limit
	planned time.Duration
	params  SearchParams
}

// BotPool is the Bot actor: a fixed number of search slots. Searches run
// outside the server lock; results go back through ServerCore.applyBotResult
// (BotMoveChosen), which checks game, seat and turn revision.
type BotPool struct {
	slots chan struct{}
	done  chan struct{}
	wg    sync.WaitGroup
}

func newBotPool(n int) *BotPool {
	return &BotPool{slots: make(chan struct{}, n), done: make(chan struct{})}
}

// botSlotCount matches the Bot population bound of eight.
func botSlotCount() int {
	n := runtime.NumCPU() / 2
	if n < 1 {
		n = 1
	}
	if n > 8 {
		n = 8
	}
	return n
}

// dispatch is called with the server lock held; it never blocks.
func (b *BotPool) dispatch(s *ServerCore, job botJob) {
	b.wg.Add(1)
	go func() {
		defer b.wg.Done()
		select {
		case b.slots <- struct{}{}:
		case <-b.done:
			return
		}
		job.params.Budget = job.budget
		job.params.Planned = job.planned
		job.params.Cancel = b.done
		job.params.Seed = time.Now().UnixNano()
		res := Search(job.geom, job.state, job.params)
		<-b.slots
		s.applyBotResult(job, res)
	}()
}

func (b *BotPool) close() { close(b.done) }
func (b *BotPool) wait()  { b.wg.Wait() }
