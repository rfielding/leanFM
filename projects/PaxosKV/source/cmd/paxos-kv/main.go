// requirement:paxos_kv.visible_behavior -- executable bindings for WebApp and KVReplica.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"leanfm/paxoskv/internal/metrics"
	"leanfm/paxoskv/internal/paxos"
	"leanfm/paxoskv/internal/trace"
	webapp "leanfm/paxoskv/internal/web"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "replica":
		replica(os.Args[2:])
	case "web":
		web(os.Args[2:])
	default:
		usage()
	}
}
func usage() { fmt.Fprintln(os.Stderr, "usage: paxos-kv replica|web [flags]"); os.Exit(2) }
func peerMap(raw string) map[string]string {
	m := map[string]string{}
	for _, part := range strings.Split(raw, ",") {
		pair := strings.SplitN(part, "=", 2)
		if len(pair) == 2 && pair[0] != "" && pair[1] != "" {
			m[pair[0]] = pair[1]
		}
	}
	return m
}
func addresses(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for _, a := range m {
		out = append(out, a)
	}
	return out
}
func signalContext() (context.Context, context.CancelFunc) {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	return ctx, cancel
}
func replica(args []string) {
	f := flag.NewFlagSet("replica", flag.ExitOnError)
	id := f.String("id", "", "replica id")
	addr := f.String("addr", "", "listen address")
	peers := f.String("peers", "", "comma-separated id=address membership")
	data := f.String("data", "", "durable data directory")
	tracePath := f.String("trace", "", "optional JSONL event path")
	f.Parse(args)
	membership := peerMap(*peers)
	if *id == "" || *addr == "" || *data == "" || len(membership) != 3 {
		log.Fatal("replica requires -id, -addr, -data, and exactly three -peers")
	}
	if membership[*id] != *addr {
		log.Fatal("-addr must match this id in -peers")
	}
	tr, e := trace.Open(*tracePath)
	if e != nil {
		log.Fatal(e)
	}
	defer tr.Close()
	node, e := paxos.NewNode(*id, *addr, *data, membership, tr)
	if e != nil {
		log.Fatal(e)
	}
	defer node.Close()
	ctx, cancel := signalContext()
	defer cancel()
	log.Printf("replica %s listening on %s", *id, *addr)
	if e = node.Serve(ctx); e != nil {
		log.Fatal(e)
	}
}
func web(args []string) {
	f := flag.NewFlagSet("web", flag.ExitOnError)
	addr := f.String("addr", "127.0.0.1:8088", "HTTP listen address")
	replicas := f.String("replicas", "127.0.0.1:9100,127.0.0.1:9101,127.0.0.1:9102", "comma-separated replica addresses")
	f.Parse(args)
	m := &metrics.Metrics{}
	app := webapp.New(strings.Split(*replicas, ","), m)
	srv := &http.Server{Addr: *addr, Handler: app.Routes(), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
	ctx, cancel := signalContext()
	defer cancel()
	go func() {
		<-ctx.Done()
		shutdown, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		srv.Shutdown(shutdown)
	}()
	log.Printf("web app listening on http://%s", *addr)
	if e := srv.ListenAndServe(); e != nil && e != http.ErrServerClosed {
		log.Fatal(e)
	}
}
