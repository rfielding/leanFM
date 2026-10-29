// requirement:web.simple_form -- render key/value input followed by a linearizable listing.
package web

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"html/template"
	"net/http"
	"sort"
	"time"

	"leanfm/paxoskv/internal/metrics"
	"leanfm/paxoskv/internal/paxos"
	webtemplates "leanfm/paxoskv/web/templates"
)

type row struct{ Key, Value string }
type page struct {
	Rows  []row
	Error string
	Slot  uint64
}
type App struct {
	Replicas []string
	Metrics  *metrics.Metrics
	sem      chan struct{}
	tmpl     *template.Template
}

func New(replicas []string, m *metrics.Metrics) *App {
	return &App{Replicas: replicas, Metrics: m, sem: make(chan struct{}, 64), tmpl: template.Must(template.New("index").Parse(webtemplates.Index))}
}
func randomID() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		return time.Now().Format("20060102150405.000000000")
	}
	return hex.EncodeToString(b[:])
}
func (a *App) session(w http.ResponseWriter, r *http.Request) string {
	if c, e := r.Cookie("paxos_session"); e == nil && c.Value != "" {
		return c.Value
	}
	id := randomID()
	http.SetCookie(w, &http.Cookie{Name: "paxos_session", Value: id, Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode})
	return id
}
func (a *App) handler(w http.ResponseWriter, r *http.Request) {
	select {
	case a.sem <- struct{}{}:
		defer func() { <-a.sem }()
	default:
		http.Error(w, "too many in-flight requests", http.StatusServiceUnavailable)
		return
	}
	session := a.session(w, r)
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	reqID := randomID()
	var respErr error
	var entriesResp map[string]string
	var slot uint64
	if r.Method == http.MethodPost && r.URL.Path == "/put" {
		r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
		if e := r.ParseForm(); e != nil {
			http.Error(w, "invalid form", http.StatusBadRequest)
			return
		}
		start := time.Now()
		resp, e := paxos.ClientPut(ctx, a.Replicas, session, reqID, r.FormValue("key"), r.FormValue("value"))
		a.Metrics.ObservePut(start, e == nil)
		respErr = e
		if e == nil {
			entriesResp = map[string]string{}
			for _, x := range resp.Entries {
				entriesResp[x.Key] = x.Value
			}
			slot = resp.Slot
		}
	} else if r.Method == http.MethodGet && r.URL.Path == "/" {
		resp, e := paxos.ClientList(ctx, a.Replicas, session, reqID)
		a.Metrics.ObserveList(e == nil)
		respErr = e
		if e == nil {
			entriesResp = map[string]string{}
			for _, x := range resp.Entries {
				entriesResp[x.Key] = x.Value
			}
			slot = resp.Slot
		}
	} else {
		http.NotFound(w, r)
		return
	}
	p := page{Error: errorString(respErr), Slot: slot}
	keys := make([]string, 0, len(entriesResp))
	for k := range entriesResp {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		p.Rows = append(p.Rows, row{k, entriesResp[k]})
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if respErr != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	_ = a.tmpl.Execute(w, p)
}
func errorString(e error) string {
	if e == nil {
		return ""
	}
	return e.Error()
}
func (a *App) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", a.handler)
	mux.HandleFunc("/put", a.handler)
	mux.Handle("/metrics", a.Metrics)
	return mux
}
