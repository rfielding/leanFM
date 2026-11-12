package goserver

// Requirement refs: property:claim_name binds a password to the session's own name;
// property:sign_in honours claims; property:claims and results are durable;
// proof:sign_in never lets anyone borrow a claimed name; proof:claim_name never takes
// another name; proof:the data file never escapes or corrupts.

import (
	"bufio"
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	MinPasswordBytes    = 8
	MaxPasswordBytes    = 128
	MaxClaims           = 1000
	MaxResults          = 100000
	DefaultPBKDF2Rounds = 600000
	// failures per name before attempts are delayed, and the longest delay
	FreeFailures = 5
	MaxThrottle  = 15 * time.Minute
	DataFileName = "goserver.jsonl"
	// one data line: a claim, or a result with at most MaxPlayers seats
	maxRecordBytes = 16384
)

// Errors a caller may show; none reveals a hash, and a wrong password says only that.
var (
	ErrClaimed      = errors.New("this name is claimed; enter its password")
	ErrNotClaimed   = errors.New("this name is not claimed; leave the password empty")
	ErrWrongPass    = errors.New("wrong password")
	ErrThrottled    = errors.New("too many wrong passwords for this name; try again later")
	ErrBotName      = errors.New("names beginning bot- belong to bots")
	ErrPasswordSize = fmt.Errorf("a password has %d to %d bytes", MinPasswordBytes, MaxPasswordBytes)
)

// nameKey is the claim identity of a display name: claims ignore case and surrounding space.
func nameKey(name string) string { return strings.ToLower(strings.TrimSpace(name)) }

func isBotName(name string) bool { return strings.HasPrefix(nameKey(name), "bot-") }

type claim struct {
	Name      string `json:"name"`
	Key       string `json:"key"`
	Hash      string `json:"hash"`
	ClaimedAt int64  `json:"at"`
}

// ResultSeat is one seat of a finished game as the ranking sees it: Player is the
// rated key (a claimed name, or bot:<settings>) or empty for an unrated seat.
type ResultSeat struct {
	Player string `json:"player"`
	Kind   string `json:"kind"` // person, bot or "" when unrated
	Team   uint32 `json:"team"`
	Place  uint32 `json:"place"` // 1 = first; equal places tie
}

// ResultRecord is one finished game; ID is random, so it stays unique across restarts.
type ResultRecord struct {
	ID         string       `json:"id"`
	GameID     string       `json:"game"`
	FinishedAt int64        `json:"at"`
	Seats      []ResultSeat `json:"seats"`
}

type record struct {
	Type   string        `json:"type"`
	Claim  *claim        `json:"claim,omitempty"`
	Result *ResultRecord `json:"result,omitempty"`
}

type failures struct {
	count    int
	last     time.Time
	inFlight bool
}

// Accounts holds claims and rated results, durable in one append-only JSON-lines file
// when a directory is given; with none (tests, embedded use) it lives in memory.
type Accounts struct {
	mu       sync.Mutex
	path     string
	file     *os.File
	claims   map[string]*claim
	results  []ResultRecord
	seen     map[string]bool
	fails    map[string]*failures
	hashers  chan struct{}
	rounds   int
	now      func() time.Time
	ranking  *Ranking // cached fit; nil after a new result
	failNext error    // test hook: the next append fails
}

func NewMemoryAccounts() *Accounts {
	return &Accounts{claims: map[string]*claim{}, seen: map[string]bool{}, fails: map[string]*failures{},
		hashers: make(chan struct{}, 2), rounds: DefaultPBKDF2Rounds, now: time.Now}
}

// DefaultDataDir is <project>/data when the working directory is the project's source
// directory (spec/runtime.json one level up); otherwise the caller must name one.
func DefaultDataDir(cwd string) (string, error) {
	project := filepath.Clean(filepath.Join(cwd, ".."))
	if _, err := os.Stat(filepath.Join(project, "spec", "runtime.json")); err != nil {
		return "", errors.New("set GOSERVER_DATA_DIR: the working directory is not the project's source directory")
	}
	dir := filepath.Join(project, "data")
	if rel, err := filepath.Rel(project, dir); err != nil || strings.HasPrefix(rel, "..") {
		return "", errors.New("data directory escapes the project root")
	}
	return dir, nil
}

// OpenAccounts replays dir/goserver.jsonl and keeps it open for appends. A torn final
// line (a crash mid-write) is cut away; any other damaged line refuses the start.
func OpenAccounts(dir string) (*Accounts, error) {
	a := NewMemoryAccounts()
	if info, err := os.Lstat(dir); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return nil, fmt.Errorf("data directory %s is a symlink or not a directory", dir)
		}
	} else if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, err
		}
	} else {
		return nil, err
	}
	a.path = filepath.Join(dir, DataFileName)
	if info, err := os.Lstat(a.path); err == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular()) {
		return nil, fmt.Errorf("data file %s is a symlink or not a regular file", a.path)
	}
	f, err := os.OpenFile(a.path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		f.Close()
		return nil, err
	}
	good := 0
	lineNo := 0
	for good < len(data) {
		end := bytes.IndexByte(data[good:], '\n')
		if end < 0 {
			break // torn tail: written without its newline
		}
		lineNo++
		line := data[good : good+end]
		if err := a.replay(line); err != nil {
			f.Close()
			return nil, fmt.Errorf("data file %s line %d is damaged (%v); restore it from a backup or move it aside", a.path, lineNo, err)
		}
		good += end + 1
	}
	if good < len(data) {
		if err := f.Truncate(int64(good)); err != nil {
			f.Close()
			return nil, err
		}
	}
	if _, err := f.Seek(int64(good), io.SeekStart); err != nil {
		f.Close()
		return nil, err
	}
	a.file = f
	return a, nil
}

func (a *Accounts) replay(line []byte) error {
	if len(line) > maxRecordBytes {
		return errors.New("record too long")
	}
	var r record
	d := json.NewDecoder(bytes.NewReader(line))
	d.DisallowUnknownFields()
	if err := d.Decode(&r); err != nil {
		return err
	}
	switch {
	case r.Type == "claim" && r.Claim != nil:
		c := r.Claim
		if c.Key != nameKey(c.Name) || !validName(c.Name) || !strings.HasPrefix(c.Hash, "pbkdf2-sha256$") {
			return errors.New("malformed claim")
		}
		if _, dup := a.claims[c.Key]; dup || len(a.claims) >= MaxClaims {
			return errors.New("duplicate claim or too many claims")
		}
		a.claims[c.Key] = c
	case r.Type == "result" && r.Result != nil:
		if r.Result.ID == "" || len(r.Result.Seats) > MaxPlayers {
			return errors.New("malformed result")
		}
		if a.seen[r.Result.ID] {
			return nil // already counted
		}
		if len(a.results) >= MaxResults {
			return errors.New("too many results")
		}
		a.seen[r.Result.ID] = true
		a.results = append(a.results, *r.Result)
	default:
		return errors.New("unknown record")
	}
	return nil
}

// append writes one whole line and flushes it; the caller holds a.mu.
func (a *Accounts) append(r record) error {
	if a.failNext != nil {
		err := a.failNext
		a.failNext = nil
		return err
	}
	if a.file == nil {
		return nil
	}
	line, err := json.Marshal(r)
	if err != nil {
		return err
	}
	w := bufio.NewWriterSize(a.file, len(line)+1)
	w.Write(line)
	w.WriteByte('\n')
	if err := w.Flush(); err != nil {
		return err
	}
	return a.file.Sync()
}

func (a *Accounts) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.file == nil {
		return nil
	}
	err := a.file.Close()
	a.file = nil
	return err
}

// Claim returns the claim for a name (ignoring case), if any.
func (a *Accounts) Claim(name string) (claimName string, claimedAt int64, ok bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	c, ok := a.claims[nameKey(name)]
	if !ok {
		return "", 0, false
	}
	return c.Name, c.ClaimedAt, true
}

// claimedExactly reports whether name itself (not a case variant) was claimed before t.
func (a *Accounts) claimedBefore(name string, t time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	c, ok := a.claims[nameKey(name)]
	return ok && c.Name == name && c.ClaimedAt < t.UnixMilli()
}

// pbkdf2Key is PBKDF2 (RFC 8018) with HMAC over h; standard library only.
func pbkdf2Key(h func() hash.Hash, password string, salt []byte, rounds, keyLen int) ([]byte, error) {
	if rounds < 1 || keyLen < 1 {
		return nil, errors.New("invalid PBKDF2 parameters")
	}
	prf := hmac.New(h, []byte(password))
	size := prf.Size()
	out := make([]byte, 0, keyLen+size)
	u := make([]byte, size)
	block := make([]byte, size)
	for i := uint32(1); len(out) < keyLen; i++ {
		prf.Reset()
		prf.Write(salt)
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], i)
		prf.Write(n[:])
		u = prf.Sum(u[:0])
		copy(block, u)
		for r := 1; r < rounds; r++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(u[:0])
			for j := range block {
				block[j] ^= u[j]
			}
		}
		out = append(out, block...)
	}
	return out[:keyLen], nil
}

func (a *Accounts) hash(password string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", errors.New("randomness unavailable")
	}
	a.hashers <- struct{}{}
	key, err := pbkdf2Key(sha256.New, password, salt, a.rounds, 32)
	<-a.hashers
	if err != nil {
		return "", err
	}
	enc := base64.RawStdEncoding
	return "pbkdf2-sha256$" + strconv.Itoa(a.rounds) + "$" + enc.EncodeToString(salt) + "$" + enc.EncodeToString(key), nil
}

func (a *Accounts) verify(stored, password string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	rounds, err := strconv.Atoi(parts[1])
	if err != nil || rounds < 1 || rounds > 10_000_000 {
		return false
	}
	enc := base64.RawStdEncoding
	salt, err1 := enc.DecodeString(parts[2])
	want, err2 := enc.DecodeString(parts[3])
	if err1 != nil || err2 != nil || len(want) == 0 {
		return false
	}
	a.hashers <- struct{}{}
	got, err := pbkdf2Key(sha256.New, password, salt, rounds, len(want))
	<-a.hashers
	return err == nil && subtle.ConstantTimeCompare(got, want) == 1
}

// throttleDelay is how long after the last failure the next attempt must wait.
func throttleDelay(count int) time.Duration {
	if count < FreeFailures {
		return 0
	}
	d := time.Second << uint(min(count-FreeFailures, 20))
	return min(d, MaxThrottle)
}

// Authenticate checks a password for a claimed name and returns its display name.
// Wrong passwords are counted per name; while delayed, or while another attempt for
// the name is being checked, the attempt is refused before any hashing.
func (a *Accounts) Authenticate(name, password string) (string, error) {
	key := nameKey(name)
	a.mu.Lock()
	c, ok := a.claims[key]
	if !ok {
		a.mu.Unlock()
		return "", ErrNotClaimed
	}
	f := a.fails[key]
	if f == nil {
		f = &failures{}
		a.fails[key] = f
	}
	if f.inFlight || (f.count >= FreeFailures && a.now().Sub(f.last) < throttleDelay(f.count)) {
		a.mu.Unlock()
		return "", ErrThrottled
	}
	if password == "" {
		a.mu.Unlock()
		return "", ErrClaimed
	}
	f.inFlight = true
	stored, display := c.Hash, c.Name
	a.mu.Unlock()
	good := len(password) <= MaxPasswordBytes && a.verify(stored, password)
	a.mu.Lock()
	defer a.mu.Unlock()
	f.inFlight = false
	if !good {
		f.count++
		f.last = a.now()
		return "", ErrWrongPass
	}
	delete(a.fails, key)
	return display, nil
}

// AddClaim hashes the password and durably records the claim for name.
func (a *Accounts) AddClaim(name, password string) (code string) {
	if len(password) < MinPasswordBytes || len(password) > MaxPasswordBytes {
		return "invalid_password"
	}
	if isBotName(name) || !validName(name) {
		return "invalid_name"
	}
	key := nameKey(name)
	a.mu.Lock()
	_, taken := a.claims[key]
	full := len(a.claims) >= MaxClaims
	a.mu.Unlock()
	if taken {
		return "already_claimed"
	}
	if full {
		return "capacity"
	}
	h, err := a.hash(password)
	if err != nil {
		return "unavailable"
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, taken := a.claims[key]; taken {
		return "already_claimed"
	}
	if len(a.claims) >= MaxClaims {
		return "capacity"
	}
	c := &claim{Name: name, Key: key, Hash: h, ClaimedAt: a.now().UnixMilli()}
	if err := a.append(record{Type: "claim", Claim: c}); err != nil {
		return "unavailable"
	}
	a.claims[key] = c
	return ""
}

func newRecordID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}

// RecordResult durably adds a finished game; it is ignored unless it is rated.
func (a *Accounts) RecordResult(r ResultRecord) error {
	if !Rated(r) {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if r.ID == "" || a.seen[r.ID] {
		return errors.New("result has no identity or was already recorded")
	}
	if len(a.results) >= MaxResults {
		return errors.New("the ranking holds its maximum number of games")
	}
	if err := a.append(record{Type: "result", Result: &r}); err != nil {
		return err
	}
	a.seen[r.ID] = true
	a.results = append(a.results, r)
	a.ranking = nil
	return nil
}

// Ranking returns the cached fit, computing it after any new result.
func (a *Accounts) Ranking() *Ranking {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.ranking == nil {
		a.ranking = Fit(a.results)
	}
	return a.ranking
}
