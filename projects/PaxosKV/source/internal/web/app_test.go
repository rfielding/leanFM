package web

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"leanfm/paxoskv/internal/metrics"
	"leanfm/paxoskv/internal/protocol"
)

func fakeReplica(t *testing.T) (string, context.CancelFunc) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	ctx, cancel := context.WithCancel(context.Background())
	var mu sync.Mutex
	values := map[string]string{}
	go func() {
		go func(){ <-ctx.Done(); l.Close() }()
		for { c,e:=l.Accept(); if e!=nil{return}; go func(){ defer c.Close(); req,e:=protocol.ReadFrame(c);if e!=nil{return};mu.Lock();if req.Type=="client_put"{values[req.Key]=req.Value};resp:=protocol.Envelope{Type:req.Type+"_result",Success:true,Slot:uint64(len(values))};for k,v:=range values{resp.Entries=append(resp.Entries,protocol.Entry{Key:k,Value:v})};mu.Unlock();_ = protocol.WriteFrame(c,resp)}() }
	}()
	return l.Addr().String(),cancel
}
func TestFormThenEscapedListingAndTwoSessions(t *testing.T){addr,cancel:=fakeReplica(t);defer cancel();server:=httptest.NewServer(New([]string{addr},&metrics.Metrics{}).Routes());defer server.Close();clients:=[]*http.Client{{},{}};vals:=[]url.Values{{"key":{"alpha"},"value":{"<script>one</script>"}},{"key":{"beta"},"value":{"two"}}};var wg sync.WaitGroup;for i:=range clients{wg.Add(1);go func(i int){defer wg.Done();resp,e:=clients[i].PostForm(server.URL+"/put",vals[i]);if e!=nil{t.Error(e);return};io.Copy(io.Discard,resp.Body);resp.Body.Close();if resp.StatusCode!=http.StatusOK{t.Errorf("status %d",resp.StatusCode)}}(i)};wg.Wait();resp,e:=http.Get(server.URL+"/");if e!=nil{t.Fatal(e)};body,_:=io.ReadAll(resp.Body);resp.Body.Close();text:=string(body);if !strings.Contains(text,"alpha")||!strings.Contains(text,"beta"){t.Fatalf("missing concurrent writes: %s",text)};if strings.Contains(text,"<script>one</script>")||!strings.Contains(text,"&lt;script&gt;one&lt;/script&gt;"){t.Fatalf("HTML not escaped: %s",text)};if !strings.Contains(text,"<form")||strings.Index(text,"<form")>strings.Index(text,"<table"){t.Fatal("form must precede listing")}}
