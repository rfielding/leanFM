// A one-page reverse proxy for leanfm-mcp on a public host (clause selfhost.mcp.proxy): Go's HTTP
// server at the edge (timeouts, TLS, keep-alive, a body cap, a concurrency cap), the Lean server on
// loopback behind it. Only /mcp and /healthz are forwarded; the client's X-Forwarded-For is replaced
// by the address the connection came from, so leanfm-mcp can trust it (LEANFM_MCP_TRUST_PROXY=1).
package main

import (
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"time"
)

type settings struct {
	listen, cert, key string
	upstream          *url.URL
	maxBody           int64
	inflight          int
	header, request   time.Duration
	idle              time.Duration
}

// config reads every setting from the environment once; a value that does not parse is an error
// naming its variable, so a misconfigured proxy stops at startup.
func config(env func(string) string) (settings, error) {
	str := func(name, def string) string {
		if v := env(name); v != "" {
			return v
		}
		return def
	}
	num := func(name string, def int64) (int64, error) {
		v := env(name)
		if v == "" {
			return def, nil
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 1 {
			return 0, fmt.Errorf("%s must be a whole number of at least 1, not %q", name, v)
		}
		return n, nil
	}
	s := settings{listen: str("LEANFM_PROXY_LISTEN", ":8443"), cert: env("LEANFM_PROXY_CERT"), key: env("LEANFM_PROXY_KEY")}
	if (s.cert == "") != (s.key == "") {
		return s, fmt.Errorf("LEANFM_PROXY_CERT and LEANFM_PROXY_KEY must be set together")
	}
	u, err := url.Parse(str("LEANFM_PROXY_UPSTREAM", "http://127.0.0.1:8090"))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return s, fmt.Errorf("LEANFM_PROXY_UPSTREAM must be an http or https URL")
	}
	s.upstream = u
	if s.maxBody, err = num("LEANFM_PROXY_MAX_BODY", 256*1024); err != nil {
		return s, err
	}
	n, err := num("LEANFM_PROXY_INFLIGHT", 32)
	if err != nil {
		return s, err
	}
	s.inflight = int(n)
	for _, t := range []struct {
		name string
		def  int64
		dst  *time.Duration
	}{{"LEANFM_PROXY_HEADER_SECONDS", 10, &s.header}, {"LEANFM_PROXY_REQUEST_SECONDS", 60, &s.request}, {"LEANFM_PROXY_IDLE_SECONDS", 60, &s.idle}} {
		v, err := num(t.name, t.def)
		if err != nil {
			return s, err
		}
		*t.dst = time.Duration(v) * time.Second
	}
	return s, nil
}

// handler forwards the two allowed routes, capping body size and requests in flight.
func handler(s settings) http.Handler {
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.Out.Header.Del("X-Forwarded-For")
			r.Out.Header.Del("X-Forwarded-Host")
			r.Out.Header.Del("X-Forwarded-Proto")
			r.SetURL(s.upstream)
			r.SetXForwarded() // the peer's address, never the client's claim
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			if _, tooBig := err.(*http.MaxBytesError); tooBig {
				http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
				return
			}
			http.Error(w, "upstream unavailable", http.StatusBadGateway)
		},
	}
	slots := make(chan struct{}, s.inflight)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		allowed := (r.URL.Path == "/mcp" && (r.Method == http.MethodPost || r.Method == http.MethodOptions)) ||
			(r.URL.Path == "/healthz" && r.Method == http.MethodGet)
		if !allowed {
			http.NotFound(w, r)
			return
		}
		if r.ContentLength > s.maxBody {
			http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			http.Error(w, "too many requests in flight", http.StatusServiceUnavailable)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, s.maxBody)
		proxy.ServeHTTP(w, r)
	})
}

func main() {
	s, err := config(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{Addr: s.listen, Handler: handler(s), ReadHeaderTimeout: s.header,
		ReadTimeout: s.request, WriteTimeout: s.request, IdleTimeout: s.idle}
	log.Printf("leanfm proxy on %s to %s (tls %v)", s.listen, s.upstream, s.cert != "")
	if s.cert != "" {
		log.Fatal(srv.ListenAndServeTLS(s.cert, s.key))
	}
	log.Fatal(srv.ListenAndServe())
}
