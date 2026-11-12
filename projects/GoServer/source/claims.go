package goserver

// Requirement refs: grammar:sign_in; grammar:claim_name; grammar:ranking;
// property:sign_in honours claims; property:claim_name binds a password to the
// session's own name; property:ranking is computed from rated games.

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
)

type ClaimName struct {
	Identity  string `json:"identity"`
	Password  string `json:"password"`
	RequestID uint64 `json:"requestId"`
}
type NameClaimed struct {
	SessionID string `json:"session"`
	Identity  string `json:"identity"`
	RequestID uint64 `json:"requestId"`
}
type ChangePassword struct {
	Identity    string `json:"identity"`
	Password    string `json:"password"`
	NewPassword string `json:"newPassword"`
	RequestID   uint64 `json:"requestId"`
}
type PasswordChanged struct {
	SessionID string `json:"session"`
	Identity  string `json:"identity"`
	RequestID uint64 `json:"requestId"`
}
type SignOut struct {
	SessionID string `json:"sessionId"`
	RequestID uint64 `json:"requestId"`
}
type SignedOut struct {
	RequestID uint64 `json:"requestId"`
}
type GetRanking struct {
	SessionID string `json:"sessionId"`
	RequestID uint64 `json:"requestId"`
}
type RankingListed struct {
	Entries    []RankEntry `json:"entries"`
	RatedGames uint32      `json:"ratedGames"`
	RequestID  uint64      `json:"requestId"`
}

// SessionIssued is the result of SignIn; the identity is the claim's own spelling.
type SessionIssued struct {
	SessionID string `json:"session"`
	Identity  string `json:"identity"`
	Claimed   bool   `json:"claimed"`
}

// NewServerWith uses the given accounts (durable or in memory) for claims and the ranking.
func NewServerWith(a *Accounts) *ServerCore {
	s := NewServer()
	s.accounts = a
	a.now = func() time.Time { return s.clock() }
	return s
}

// Accounts exposes the claim and ranking store, for the HTTP adapter and tests.
func (s *ServerCore) Accounts() *Accounts { return s.accounts }

// SignIn issues a session for a name. A claimed name needs its password; with it, every
// older session for the name ends and the person keeps their rooms, games and seats.
func (s *ServerCore) SignIn(identity, password string) (SessionIssued, error) {
	if !validName(identity) {
		return SessionIssued{}, errors.New("invalid identity")
	}
	if isBotName(identity) {
		return SessionIssued{}, ErrBotName
	}
	claimed := false
	if _, _, ok := s.accounts.Claim(identity); ok {
		display, err := s.accounts.Authenticate(identity, password)
		if err != nil {
			return SessionIssued{}, err
		}
		identity, claimed = display, true
	} else if password != "" {
		return SessionIssued{}, ErrNotClaimed
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !claimed {
		for _, existing := range s.sessions {
			if existing == identity {
				return SessionIssued{}, errors.New("identity already in use; choose another local demo name")
			}
		}
	}
	token, err := s.issueLocked(identity, claimed)
	if err != nil {
		return SessionIssued{}, err
	}
	return SessionIssued{SessionID: token, Identity: identity, Claimed: claimed}, nil
}

// issueLocked makes a new session; for a claimed name every older session ends first.
func (s *ServerCore) issueLocked(identity string, claimed bool) (string, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", errors.New("session randomness unavailable")
	}
	if claimed {
		for t, who := range s.sessions {
			if who == identity {
				delete(s.sessions, t)
				delete(s.cache, t)
			}
		}
	}
	if len(s.sessions) >= MaxSessions {
		return "", errors.New("session capacity reached")
	}
	token := hex.EncodeToString(secret)
	s.sessions[token] = identity
	return token, nil
}

// claimName claims an unclaimed name from the sign-in form and signs the person in. It is
// never routed through the replay cache, so the password is never retained.
func (s *ServerCore) claimName(r ClaimName) any {
	name := r.Identity
	if !validName(name) || isBotName(name) {
		return reject(r.RequestID, "invalid_name", "claim_name")
	}
	s.mu.RLock()
	for _, other := range s.sessions {
		if nameKey(other) == nameKey(name) {
			s.mu.RUnlock()
			return reject(r.RequestID, "name_in_use", "claim_name")
		}
	}
	s.mu.RUnlock()
	if code := s.accounts.AddClaim(name, r.Password); code != "" {
		return reject(r.RequestID, code, "claim_name")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	token, err := s.issueLocked(name, true)
	if err != nil {
		return reject(r.RequestID, "busy", "claim_name")
	}
	return NameClaimed{SessionID: token, Identity: name, RequestID: r.RequestID}
}

// changePassword needs the current password (throttled like sign-in); afterwards every
// older session for the name ends and the person gets a new one.
func (s *ServerCore) changePassword(r ChangePassword) any {
	display, err := s.accounts.Authenticate(r.Identity, r.Password)
	switch {
	case errors.Is(err, ErrNotClaimed):
		return reject(r.RequestID, "not_claimed", "change_password")
	case errors.Is(err, ErrThrottled):
		return reject(r.RequestID, "throttled", "change_password")
	case err != nil:
		return reject(r.RequestID, "wrong_password", "change_password")
	}
	if code := s.accounts.SetPassword(display, r.NewPassword); code != "" {
		return reject(r.RequestID, code, "change_password")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	token, err := s.issueLocked(display, true)
	if err != nil {
		return reject(r.RequestID, "busy", "change_password")
	}
	return PasswordChanged{SessionID: token, Identity: display, RequestID: r.RequestID}
}

type ReleaseName struct {
	Identity  string `json:"identity"`
	Password  string `json:"password"`
	RequestID uint64 `json:"requestId"`
}
type NameReleased struct {
	Identity  string `json:"identity"`
	RequestID uint64 `json:"requestId"`
}

// releaseName frees a claimed name after its password (throttled like sign-in); every
// session for the name ends. The browser asks for a confirmation before sending it.
func (s *ServerCore) releaseName(r ReleaseName) any {
	display, err := s.accounts.Authenticate(r.Identity, r.Password)
	switch {
	case errors.Is(err, ErrNotClaimed):
		return reject(r.RequestID, "not_claimed", "release_name")
	case errors.Is(err, ErrThrottled):
		return reject(r.RequestID, "throttled", "release_name")
	case err != nil:
		return reject(r.RequestID, "wrong_password", "release_name")
	}
	if code := s.accounts.Release(display); code != "" {
		return reject(r.RequestID, code, "release_name")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for t, who := range s.sessions {
		if who == display {
			delete(s.sessions, t)
			delete(s.cache, t)
		}
	}
	return NameReleased{Identity: display, RequestID: r.RequestID}
}

func (s *ServerCore) signOut(r SignOut) any {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.sessions[r.SessionID]; !ok {
		return reject(r.RequestID, "unauthorized", "sign_out")
	}
	delete(s.sessions, r.SessionID)
	delete(s.cache, r.SessionID)
	return SignedOut{RequestID: r.RequestID}
}

func (s *ServerCore) getRanking(r GetRanking) any {
	if _, ok := s.identityFor(r.SessionID); !ok {
		return reject(r.RequestID, "unauthorized", "ranking")
	}
	k := s.accounts.Ranking()
	return RankingListed{Entries: append([]RankEntry{}, k.Entries...), RatedGames: k.RatedGames, RequestID: r.RequestID}
}

// botKey identifies a bot by its search settings, so each setting has its own rating.
func (g *game) botKey() string {
	key := fmt.Sprintf("bot:%ds+%dx%ds/%.2f/%s", g.mainTimeMs/1000, g.byoyomiPeriods, g.byoyomiMs/1000, float64(g.exploreMilli)/1000, g.rewardMode)
	if g.rewardMode == "margin" {
		key += fmt.Sprintf("/%d", g.softness)
	}
	return key
}

// resultLocked is the finished game as the ranking sees it. Teams are placed by whether
// a member has not resigned, then team score; equal teams share a place. A person's
// seat is rated only if their exact name was claimed before the game started and the
// seat never switched to autopilot.
func (s *ServerCore) resultLocked(g *game, views []SeatView) ResultRecord {
	type standing struct {
		active bool
		score  int32
	}
	teams := map[uint32]*standing{}
	for _, t := range teamViews(views) {
		st := &standing{score: t.Score}
		for _, n := range t.Seats {
			if !views[n-1].Resigned {
				st.active = true
			}
		}
		teams[t.Team] = st
	}
	better := func(a, b *standing) bool {
		if a.active != b.active {
			return a.active
		}
		return a.score > b.score
	}
	place := func(team uint32) uint32 {
		p := uint32(1)
		for _, other := range teams {
			if better(other, teams[team]) {
				p++
			}
		}
		return p
	}
	r := ResultRecord{ID: newRecordID(), GameID: g.id, FinishedAt: s.clock().UnixMilli()}
	for i, v := range views {
		st := g.seatInfo[i]
		seat := ResultSeat{Team: v.Team, Place: place(v.Team)}
		switch {
		case st.controller == CtlBot:
			seat.Player, seat.Kind = g.botKey(), "bot"
		case st.controller == CtlPerson && !st.everAutopilot:
			if id := s.accounts.claimedBefore(st.player, g.play.startedAt); id != "" {
				seat.Player, seat.Kind, seat.Claim = st.player, "person", id
			}
		}
		r.Seats = append(r.Seats, seat)
	}
	return r
}

// recordResultLocked stores a rated result; a failure is told to the game, never hidden.
func (s *ServerCore) recordResultLocked(g *game, views []SeatView) {
	r := s.resultLocked(g, views)
	if !Rated(r) {
		return
	}
	body := "This game counts toward the ranking."
	if err := s.accounts.RecordResult(r); err != nil {
		body = "This game could not be added to the ranking: " + strings.TrimSpace(err.Error())
	}
	g.chat = appendBoundedGame(g.chat, GameChat{GameID: g.id, Sender: "server", Node: g.pinLocked(""), Body: body, TimeMS: s.clock().UnixMilli()})
}
