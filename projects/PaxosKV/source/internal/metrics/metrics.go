// requirement:output:paxos.commit_latency -- Prometheus reductions retain stable output IDs.
package metrics

import (
	"fmt"
	"net/http"
	"sync/atomic"
	"time"
)

type Metrics struct{ puts, lists, failures, commitNanos, commitCount atomic.Uint64 }

func (m *Metrics) ObservePut(start time.Time, ok bool) {
	if ok {
		m.puts.Add(1)
		m.commitNanos.Add(uint64(time.Since(start)))
		m.commitCount.Add(1)
	} else {
		m.failures.Add(1)
	}
}
func (m *Metrics) ObserveList(ok bool) {
	if ok {
		m.lists.Add(1)
	} else {
		m.failures.Add(1)
	}
}
func (m *Metrics) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP paxos_kv_requests_total Browser request outcomes.\n# TYPE paxos_kv_requests_total counter\npaxos_kv_requests_total{output_id=\"paxos.outcomes\",kind=\"put_success\"} %d\npaxos_kv_requests_total{output_id=\"paxos.outcomes\",kind=\"list_success\"} %d\npaxos_kv_requests_total{output_id=\"paxos.outcomes\",kind=\"failure\"} %d\n", m.puts.Load(), m.lists.Load(), m.failures.Load())
	fmt.Fprintf(w, "# HELP paxos_kv_commit_latency_nanoseconds_total Write latency accumulator.\n# TYPE paxos_kv_commit_latency_nanoseconds_total counter\npaxos_kv_commit_latency_nanoseconds_total{output_id=\"paxos.commit_latency\"} %d\npaxos_kv_commit_latency_count{output_id=\"paxos.commit_latency\"} %d\n", m.commitNanos.Load(), m.commitCount.Load())
	fmt.Fprintln(w, "paxos_kv_required_quorum{output_id=\"paxos.quorum_size\"} 2")
}
