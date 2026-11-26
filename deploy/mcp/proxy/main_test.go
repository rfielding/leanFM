package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testSettings(t *testing.T, upstream string, extra map[string]string) settings {
	env := map[string]string{"LEANFM_PROXY_UPSTREAM": upstream}
	for k, v := range extra {
		env[k] = v
	}
	s, err := config(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestForwardsMcpWithThePeerAddress(t *testing.T) {
	var gotBody, gotXFF string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody, gotXFF = string(b), r.Header.Get("X-Forwarded-For")
		w.Write([]byte("ok"))
	}))
	defer up.Close()
	front := httptest.NewServer(handler(testSettings(t, up.URL, nil)))
	defer front.Close()
	req, _ := http.NewRequest(http.MethodPost, front.URL+"/mcp", strings.NewReader(`{"jsonrpc":"2.0"}`))
	req.Header.Set("X-Forwarded-For", "6.6.6.6")
	res, err := http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != 200 {
		t.Fatalf("forward failed: %v %v", err, res)
	}
	if gotBody != `{"jsonrpc":"2.0"}` {
		t.Fatalf("body changed: %q", gotBody)
	}
	if gotXFF != "127.0.0.1" {
		t.Fatalf("X-Forwarded-For should be the peer, not the client's claim: %q", gotXFF)
	}
}

func TestOtherPathsAre404(t *testing.T) {
	front := httptest.NewServer(handler(testSettings(t, "http://127.0.0.1:1", nil)))
	defer front.Close()
	for _, p := range []string{"/", "/renders/x", "/api/llm"} {
		res, _ := http.Get(front.URL + p)
		if res.StatusCode != 404 {
			t.Fatalf("%s: %d", p, res.StatusCode)
		}
	}
}

func TestBodyOverTheCapIs413AndNeverForwarded(t *testing.T) {
	reached := false
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached = true }))
	defer up.Close()
	front := httptest.NewServer(handler(testSettings(t, up.URL, map[string]string{"LEANFM_PROXY_MAX_BODY": "10"})))
	defer front.Close()
	res, _ := http.Post(front.URL+"/mcp", "application/json", strings.NewReader(strings.Repeat("x", 100)))
	if res.StatusCode != 413 || reached {
		t.Fatalf("status %d, reached upstream %v", res.StatusCode, reached)
	}
}

func TestOverTheConcurrencyCapIs503(t *testing.T) {
	release := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	defer up.Close()
	front := httptest.NewServer(handler(testSettings(t, up.URL, map[string]string{"LEANFM_PROXY_INFLIGHT": "1"})))
	defer front.Close()
	go http.Post(front.URL+"/mcp", "application/json", strings.NewReader("{}"))
	time.Sleep(200 * time.Millisecond)
	res, _ := http.Post(front.URL+"/mcp", "application/json", strings.NewReader("{}"))
	close(release)
	if res.StatusCode != 503 {
		t.Fatalf("status %d", res.StatusCode)
	}
}

func TestBadSettingsAreRefused(t *testing.T) {
	for _, env := range []map[string]string{
		{"LEANFM_PROXY_INFLIGHT": "many"}, {"LEANFM_PROXY_MAX_BODY": "0"},
		{"LEANFM_PROXY_UPSTREAM": "ftp://x"}, {"LEANFM_PROXY_CERT": "a.pem"},
	} {
		if _, err := config(func(k string) string { return env[k] }); err == nil {
			t.Fatalf("accepted %v", env)
		}
	}
}
