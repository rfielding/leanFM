package main

import (
	"context"
	"flag"
	"fmt"
	"leanfm/goserver/server"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

// Requirement refs: working-contract.json R3, R6; project.json root isolation.
func main() {
	addr := flag.String("addr", "127.0.0.1:8082", "loopback listen address")
	data := flag.String("data", ".runtime", "project-relative runtime directory")
	flag.Parse()
	root, err := os.Getwd()
	if err != nil {
		log.Fatal(err)
	}
	if _, err = os.Stat(filepath.Join(root, "project.json")); err != nil {
		log.Fatal("run from the GoServer project root containing project.json")
	}
	if filepath.IsAbs(*data) || filepath.Clean(*data) == ".." || len(*data) == 0 {
		log.Fatal("data must remain beneath the project root")
	}
	full := filepath.Join(root, *data)
	rel, _ := filepath.Rel(root, full)
	if rel == ".." || (len(rel) > 3 && rel[:3] == "../") {
		log.Fatal("data path escapes project root")
	}
	// Reject every existing symlink component, including an intermediate one.
	for p := full; p != root; p = filepath.Dir(p) {
		if info, e := os.Lstat(p); e == nil && info.Mode()&os.ModeSymlink != 0 {
			log.Fatal("runtime path contains a symlink")
		}
		if filepath.Dir(p) == p {
			log.Fatal("runtime escapes root")
		}
	}
	host, _, err := net.SplitHostPort(*addr)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		log.Fatal("listen address must be an explicit loopback IP")
	}
	app, err := server.New(full)
	if err != nil {
		log.Fatal(err)
	}
	listener, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{Handler: app.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
	}()
	fmt.Printf("GoServer ready at http://%s\n", listener.Addr())
	if err = srv.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
