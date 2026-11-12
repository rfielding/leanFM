// Requirement refs: grammar:ranking; property:ranking is computed from rated games;
// property:Browser navigation reflects server state.
//
// The Ranking tab: the ranking of claimed names and bots.
import {useEffect, useState} from 'react';
import {api, auth, feedback, nextID} from '../api';

type Entry = {rank: number; player: string; kind: string; rating: number; games: number; firsts: number};

export function RankingView() {
  const [rows, setRows] = useState<Entry[] | null>(null), [games, setGames] = useState(0);
  const load = async () => { const r = await api('ranking', {requestId: nextID()}); setRows(r.entries || []); setGames(r.ratedGames || 0); };
  useEffect(() => { let alive = true, t = 0; const loop = async () => { try { await load(); } catch (e: any) { if (alive) feedback(e.message, true); } if (alive) t = window.setTimeout(loop, 10000); }; void loop(); return () => { alive = false; clearTimeout(t); }; }, []);
  return (
    <section className="ranking-page">
      <section className="panel ranking">
        <div className="section-heading"><h2>Ranking</h2><button type="button" className="subtle" onClick={() => void load().catch(e => feedback(e.message, true))}>Refresh</button></div>
        <p className="muted small">From {games} rated {games === 1 ? 'game' : 'games'}: games where seats on at least two teams are held by bots or by names claimed before the game started (a seat that used autopilot does not count). Everyone starts near 1500; beating a higher-rated player or bot moves you more.</p>
        {rows === null ? <p className="empty">Loading the ranking…</p> : !rows.length ? <p className="empty">No rated games yet. Claim your name on the sign-in form (the password typed twice), then finish a game against a bot or another claimed name.</p> :
          <table className="ranking-table"><thead><tr><th>#</th><th className="name">Player</th><th>Rating</th><th>Games</th><th>Firsts</th></tr></thead>
            <tbody>{rows.map(r => <tr key={r.kind + ':' + r.player} className={r.kind === 'person' && r.player === auth.identity ? 'me' : ''}>
              <td>{r.rank}</td><td className="name">{r.player}{r.kind === 'bot' ? <span className="kind">bot</span> : null}</td><td>{r.rating}</td><td>{r.games}</td><td>{r.firsts}</td></tr>)}</tbody></table>}
      </section>
    </section>
  );
}
