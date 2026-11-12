package goserver

// Requirement refs: property:sign_in honours claims; property:claim_name binds a password
// to the session's own name; property:ranking is computed from rated games; property:claims
// and results are durable; and their never-proofs.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fastServer uses few PBKDF2 rounds so tests stay quick; the format is unchanged.
func fastServer(t *testing.T) *ServerCore {
	t.Helper()
	a := NewMemoryAccounts()
	a.rounds = 1000
	s := NewServerWith(a)
	t.Cleanup(s.Close)
	return s
}

func TestPBKDF2MatchesRFC7914Vector(t *testing.T) {
	got, err := pbkdf2Key(sha256.New, "passwd", []byte("salt"), 1, 64)
	want := "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
	if err != nil || hex.EncodeToString(got) != want {
		t.Fatalf("PBKDF2-HMAC-SHA256 vector: %x", got)
	}
	got, _ = pbkdf2Key(sha256.New, "Password", []byte("NaCl"), 80000, 64)
	want = "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d"
	if hex.EncodeToString(got) != want {
		t.Fatalf("80000-round vector: %x", got)
	}
}

func TestClaimNameAndSignIn(t *testing.T) {
	s := fastServer(t)
	alice, _ := s.IssueSession("alice")
	if c := code(s.Handle(ClaimName{SessionID: "nope", Password: "long enough", RequestID: 1})); c != "unauthorized" {
		t.Fatalf("claim without a session: %q", c)
	}
	if c := code(s.Handle(ClaimName{SessionID: alice, Password: "short", RequestID: 2})); c != "invalid_password" {
		t.Fatalf("short password: %q", c)
	}
	if c := code(s.Handle(ClaimName{SessionID: alice, Password: strings.Repeat("x", 129), RequestID: 3})); c != "invalid_password" {
		t.Fatalf("long password: %q", c)
	}
	got := s.Handle(ClaimName{SessionID: alice, Password: "correct horse", RequestID: 4})
	if c, ok := got.(NameClaimed); !ok || c.Identity != "alice" {
		t.Fatalf("claim: %#v", got)
	}
	if raw, _ := json.Marshal(got); strings.Contains(string(raw), "correct horse") || strings.Contains(string(raw), "pbkdf2") {
		t.Fatal("claim result carries the password or its hash")
	}
	if c := code(s.Handle(ClaimName{SessionID: alice, Password: "another one", RequestID: 5})); c != "already_claimed" {
		t.Fatalf("second claim replaced the password: %q", c)
	}
	// a claimed name needs its password, in any letter case
	if _, err := s.SignIn("alice", ""); !errors.Is(err, ErrClaimed) {
		t.Fatalf("no password: %v", err)
	}
	if _, err := s.SignIn("ALICE", "wrong guess"); !errors.Is(err, ErrWrongPass) {
		t.Fatalf("case variant with a wrong password: %v", err)
	}
	if _, err := s.SignIn("bob", "a password"); !errors.Is(err, ErrNotClaimed) {
		t.Fatalf("password for an unclaimed name: %v", err)
	}
	for _, bot := range []string{"bot-1", "BOT-7", " bot-2"} {
		if _, err := s.SignIn(bot, ""); !errors.Is(err, ErrBotName) {
			t.Fatalf("person took the bot name %q: %v", bot, err)
		}
	}
	// the password ends the old session and keeps the claim's spelling
	issued, err := s.SignIn(" Alice", "correct horse")
	if err != nil || issued.Identity != "alice" || !issued.Claimed {
		t.Fatalf("sign in with password: %+v %v", issued, err)
	}
	if _, ok := s.identityFor(alice); ok {
		t.Fatal("the older session for a claimed name survived")
	}
	if who, ok := s.identityFor(issued.SessionID); !ok || who != "alice" {
		t.Fatal("new session does not hold the name")
	}
}

func TestClaimRefusedWhileACaseVariantIsInUse(t *testing.T) {
	s := fastServer(t)
	upper, _ := s.IssueSession("Carol")
	s.IssueSession("carol")
	if c := code(s.Handle(ClaimName{SessionID: upper, Password: "long enough", RequestID: 1})); c != "name_variant_in_use" {
		t.Fatalf("claimed while a case variant is live: %q", c)
	}
}

func TestWrongPasswordsAreThrottled(t *testing.T) {
	s := fastServer(t)
	now := time.Unix(1_800_000_000, 0)
	s.clock = func() time.Time { return now }
	dave, _ := s.IssueSession("dave")
	s.Handle(ClaimName{SessionID: dave, Password: "right password", RequestID: 1})
	for i := 0; i < FreeFailures; i++ {
		if _, err := s.SignIn("dave", "wrong"); !errors.Is(err, ErrWrongPass) {
			t.Fatalf("failure %d: %v", i, err)
		}
	}
	if _, err := s.SignIn("dave", "right password"); !errors.Is(err, ErrThrottled) {
		t.Fatalf("attempt during the delay was checked: %v", err)
	}
	now = now.Add(1100 * time.Millisecond)
	if _, err := s.SignIn("dave", "right password"); err != nil {
		t.Fatalf("after the delay: %v", err)
	}
	if throttleDelay(FreeFailures+30) != MaxThrottle || throttleDelay(FreeFailures+1) != 2*time.Second {
		t.Fatal("delay does not double up to the cap")
	}
}

func TestDataFileIsDurableAndRefusesDamage(t *testing.T) {
	dir := t.TempDir()
	a, err := OpenAccounts(dir)
	if err != nil {
		t.Fatal(err)
	}
	a.rounds = 1000
	if c := a.AddClaim("erin", "secret words"); c != "" {
		t.Fatal(c)
	}
	r := ResultRecord{ID: "r1", GameID: "g-1", Seats: []ResultSeat{{Player: "erin", Kind: "person", Team: 1, Place: 1}, {Player: "bot:1000ms/0.70/margin/4", Kind: "bot", Team: 2, Place: 2}}}
	if err := a.RecordResult(r); err != nil {
		t.Fatal(err)
	}
	if err := a.RecordResult(r); err == nil {
		t.Fatal("one game recorded twice")
	}
	a.Close()
	path := filepath.Join(dir, DataFileName)
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "secret words") {
		t.Fatal("plaintext password stored")
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatalf("data file mode %v", info.Mode().Perm())
	}
	// a torn final line (crash mid-write) is cut away; the rest replays
	os.WriteFile(path, append(raw, []byte(`{"type":"result","resu`)...), 0o600)
	b, err := OpenAccounts(dir)
	if err != nil {
		t.Fatalf("torn tail: %v", err)
	}
	if _, _, ok := b.Claim("ERIN"); !ok || b.Ranking().RatedGames != 1 {
		t.Fatal("claim or result lost across restart")
	}
	b.Close()
	if after, _ := os.ReadFile(path); string(after) != string(raw) {
		t.Fatal("torn tail not truncated")
	}
	// a replayed duplicate result counts once
	lines := strings.SplitAfter(string(raw), "\n")
	os.WriteFile(path, []byte(string(raw)+lines[1]), 0o600)
	c, err := OpenAccounts(dir)
	if err != nil || c.Ranking().RatedGames != 1 {
		t.Fatalf("duplicate replay: %v", err)
	}
	c.Close()
	// damage before the end refuses the start
	os.WriteFile(path, []byte("{broken\n"+string(raw)), 0o600)
	if _, err := OpenAccounts(dir); err == nil || !strings.Contains(err.Error(), "line 1") {
		t.Fatalf("damaged record accepted: %v", err)
	}
}

func TestDataPathRefusesSymlinksAndEscapes(t *testing.T) {
	root := t.TempDir()
	real := filepath.Join(root, "real")
	os.Mkdir(real, 0o700)
	link := filepath.Join(root, "link")
	os.Symlink(real, link)
	if _, err := OpenAccounts(link); err == nil {
		t.Fatal("symlinked data directory accepted")
	}
	os.Symlink(filepath.Join(root, "elsewhere"), filepath.Join(real, DataFileName))
	if _, err := OpenAccounts(real); err == nil {
		t.Fatal("symlinked data file accepted")
	}
	if _, err := DefaultDataDir(root); err == nil {
		t.Fatal("default data directory outside a project")
	}
	project := filepath.Join(root, "proj")
	os.MkdirAll(filepath.Join(project, "spec"), 0o700)
	os.MkdirAll(filepath.Join(project, "source"), 0o700)
	os.WriteFile(filepath.Join(project, "spec", "runtime.json"), []byte("{}"), 0o600)
	if dir, err := DefaultDataDir(filepath.Join(project, "source")); err != nil || dir != filepath.Join(project, "data") {
		t.Fatalf("default data directory: %q %v", dir, err)
	}
}

func TestClaimIsNotAcknowledgedUntilDurable(t *testing.T) {
	s := fastServer(t)
	fay, _ := s.IssueSession("fay")
	s.accounts.failNext = errors.New("disk full")
	if c := code(s.Handle(ClaimName{SessionID: fay, Password: "long enough", RequestID: 1})); c != "unavailable" {
		t.Fatalf("claim acknowledged without a durable record: %q", c)
	}
	if _, _, ok := s.accounts.Claim("fay"); ok {
		t.Fatal("failed claim kept in memory")
	}
}

func rs(p string, team, place uint32) ResultSeat {
	kind := "person"
	if strings.HasPrefix(p, "bot:") {
		kind = "bot"
	}
	if p == "" {
		kind = ""
	}
	return ResultSeat{Player: p, Kind: kind, Team: team, Place: place}
}

// Expected ratings come from an independent Newton's-method fit of the same model.
func TestFitMatchesIndependentNewtonFit(t *testing.T) {
	results := []ResultRecord{
		{ID: "1", Seats: []ResultSeat{rs("A", 1, 1), rs("B", 2, 2), rs("C", 3, 3)}},
		{ID: "2", Seats: []ResultSeat{rs("A", 1, 2), rs("B", 1, 2), rs("C", 2, 1)}},
		{ID: "3", Seats: []ResultSeat{rs("B", 1, 1), rs("C", 2, 1)}},
		{ID: "4", Seats: []ResultSeat{rs("bot:x", 1, 1), rs("A", 2, 2)}},
		// not rated: one team, an unrated seat only, and one bot setting against itself
		{ID: "5", Seats: []ResultSeat{rs("A", 1, 1), rs("B", 1, 1)}},
		{ID: "6", Seats: []ResultSeat{rs("A", 1, 1), rs("", 2, 2)}},
		{ID: "7", Seats: []ResultSeat{rs("bot:x", 1, 1), rs("bot:x", 2, 2)}},
	}
	k := Fit(results)
	want := map[string]float64{"A": 1521.4620938564137, "B": 1434.9975755194528, "C": 1419.1811543523409, "bot:x": 1627.6628830787267}
	for p, w := range want {
		if math.Abs(k.Exact[p]-w) > 1e-6 {
			t.Fatalf("%s: %v want %v", p, k.Exact[p], w)
		}
	}
	if k.RatedGames != 4 || len(k.Entries) != 4 || k.Entries[0].Player != "bot:x" || k.Entries[0].Rating != 1628 {
		t.Fatalf("listing: %+v", k)
	}
	if a := k.Entries[1]; a.Player != "A" || a.Games != 3 || a.Firsts != 1 {
		t.Fatalf("A's counts: %+v", a)
	}
	// the order of games never matters
	for i := 0; i < 20; i++ {
		shuffled := append([]ResultRecord{}, results...)
		rand.Shuffle(len(shuffled), func(i, j int) { shuffled[i], shuffled[j] = shuffled[j], shuffled[i] })
		again := Fit(shuffled)
		for p := range want {
			if again.Exact[p] != k.Exact[p] {
				t.Fatalf("order changed %s: %v vs %v", p, again.Exact[p], k.Exact[p])
			}
		}
	}
	if Fit(nil).RatedGames != 0 || len(Fit(nil).Entries) != 0 {
		t.Fatal("empty fit")
	}
}

// A finished game between two claimed names is rated; claims after the start, autopilot
// and unclaimed names are not.
func TestFinishedGamesFeedTheRanking(t *testing.T) {
	play := func(t *testing.T, before, after func(tb *table), autopilot bool) *Ranking {
		tb := newTable(t, CreateGame{BoardSize: 5, Seats: 2})
		tb.s.accounts.rounds = 1000
		tb.s.accounts.now = func() time.Time { return tb.s.clock() }
		s := tb.s
		before(tb)
		s.Handle(TakeSeat{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
		s.Handle(TakeSeat{SessionID: tb.bob, GameID: tb.game, RequestID: tb.id()})
		time.Sleep(2 * time.Millisecond)
		s.Handle(StartGame{SessionID: tb.alice, GameID: tb.game, RequestID: tb.id()})
		after(tb)
		if autopilot {
			s.Handle(SetAutopilot{SessionID: tb.bob, GameID: tb.game, On: true, RequestID: tb.id()})
			s.Handle(SetAutopilot{SessionID: tb.bob, GameID: tb.game, On: false, RequestID: tb.id()})
		}
		s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 0, Kind: "place", X: 2, Y: 2, RequestID: tb.id()})
		s.Handle(PlayMove{SessionID: tb.bob, GameID: tb.game, MoveNo: 1, Kind: "pass", RequestID: tb.id()})
		s.Handle(PlayMove{SessionID: tb.alice, GameID: tb.game, MoveNo: 2, Kind: "pass", RequestID: tb.id()})
		if st := tb.state(t, tb.alice); st.Status != GameFinished {
			t.Fatalf("not finished: %+v", st.Status)
		}
		return s.accounts.Ranking()
	}
	claimBoth := func(tb *table) {
		tb.s.Handle(ClaimName{SessionID: tb.alice, Password: "alice's pass", RequestID: tb.id()})
		tb.s.Handle(ClaimName{SessionID: tb.bob, Password: "bob's password", RequestID: tb.id()})
	}
	none := func(*table) {}
	k := play(t, claimBoth, none, false)
	if k.RatedGames != 1 || len(k.Entries) != 2 || k.Entries[0].Player != "alice" || k.Entries[0].Rating <= 1500 || k.Entries[1].Rating >= 1500 {
		t.Fatalf("claimed game: %+v", k.Entries)
	}
	ranked, ok := (func() any {
		s := fastServer(t)
		tok, _ := s.IssueSession("viewer")
		return s.Handle(GetRanking{SessionID: tok, RequestID: 1})
	})().(RankingListed)
	if !ok || ranked.RatedGames != 0 {
		t.Fatal("ranking listing for a valid session")
	}
	if c := code(fastServer(t).Handle(GetRanking{SessionID: "nope", RequestID: 1})); c != "unauthorized" {
		t.Fatal("ranking without a session")
	}
	if k := play(t, none, claimBoth, false); k.RatedGames != 0 {
		t.Fatalf("names claimed after the start were rated: %+v", k.Entries)
	}
	if k := play(t, claimBoth, none, true); k.RatedGames != 0 {
		t.Fatalf("an autopilot seat was rated: %+v", k.Entries)
	}
	if k := play(t, none, none, false); k.RatedGames != 0 {
		t.Fatalf("unclaimed names were rated: %+v", k.Entries)
	}
}
