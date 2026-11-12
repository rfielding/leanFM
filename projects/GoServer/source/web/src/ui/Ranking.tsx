// Requirement refs: grammar:ranking; grammar:claim_name; property:ranking is computed from rated
// games; property:claim_name binds a password to the session's own name; property:Browser
// navigation reflects server state.
//
// The Ranking tab: claim your own name with a password, and the ranking of claimed names and bots.
import {useEffect, useRef, useState} from 'react';
import {api, auth, feedback, markClaimed, nextID} from '../api';

type Entry = {rank: number; player: string; kind: string; rating: number; games: number; firsts: number};

export function RankingView() {
  const [rows, setRows] = useState<Entry[] | null>(null), [games, setGames] = useState(0);
  const load = async () => { const r = await api('ranking', {requestId: nextID()}); setRows(r.entries || []); setGames(r.ratedGames || 0); };
  useEffect(() => { let alive = true, t = 0; const loop = async () => { try { await load(); } catch (e: any) { if (alive) feedback(e.message, true); } if (alive) t = window.setTimeout(loop, 10000); }; void loop(); return () => { alive = false; clearTimeout(t); }; }, []);
  return (
    <section className="ranking-page">
      <ClaimPanel />
      <section className="panel ranking">
        <div className="section-heading"><h2>Ranking</h2><button type="button" className="subtle" onClick={() => void load().catch(e => feedback(e.message, true))}>Refresh</button></div>
        <p className="muted small">From {games} rated {games === 1 ? 'game' : 'games'}: games where seats on at least two teams are held by bots or by names claimed before the game started (a seat that used autopilot does not count). Everyone starts near 1500; beating a higher-rated player or bot moves you more.</p>
        {rows === null ? <p className="empty">Loading the ranking…</p> : !rows.length ? <p className="empty">No rated games yet. Claim your name, then finish a game against a bot or another claimed name.</p> :
          <table className="ranking-table"><thead><tr><th>#</th><th className="name">Player</th><th>Rating</th><th>Games</th><th>Firsts</th></tr></thead>
            <tbody>{rows.map(r => <tr key={r.kind + ':' + r.player} className={r.kind === 'person' && r.player === auth.identity ? 'me' : ''}>
              <td>{r.rank}</td><td className="name">{r.player}{r.kind === 'bot' ? <span className="kind">bot</span> : null}</td><td>{r.rating}</td><td>{r.games}</td><td>{r.firsts}</td></tr>)}</tbody></table>}
      </section>
    </section>
  );
}

function ClaimPanel() {
  const [claimed, setClaimed] = useState(auth.claimed), [busy, setBusy] = useState(false);
  const a = useRef<HTMLInputElement>(null), b = useRef<HTMLInputElement>(null);
  if (claimed) return <section className="panel claim"><h2>Your name</h2><p className="muted">“{auth.identity}” is claimed. Only your password gives a session for it, and your rated games count in the ranking.</p></section>;
  const submit = async (e: React.FormEvent) => {
    e.preventDefault(); if (busy || !a.current || !b.current) return;
    if (a.current.value !== b.current.value) { feedback('The two passwords differ.', true); return; }
    setBusy(true);
    try { await api('claim_name', {password: a.current.value, requestId: nextID()}); markClaimed(); setClaimed(true); feedback('Your name is claimed. Games you start from now on can count toward the ranking.'); }
    catch (err: any) { feedback(err.message, true); } finally { if (a.current) a.current.value = ''; if (b.current) b.current.value = ''; setBusy(false); }
  };
  return (
    <section className="panel claim"><h2>Claim “{auth.identity}”</h2>
      <p className="muted small">Set a password so nobody else can use this name. Only games that start after you claim it count toward the ranking. There is no password reset, so keep it safe.</p>
      <form onSubmit={submit}><div className="grid2">
        <label>Password<input ref={a} type="password" minLength={8} maxLength={128} required autoComplete="new-password" /></label>
        <label>Repeat it<input ref={b} type="password" minLength={8} maxLength={128} required autoComplete="new-password" /></label></div>
        <button type="submit" disabled={busy}>Claim my name</button></form>
    </section>
  );
}
