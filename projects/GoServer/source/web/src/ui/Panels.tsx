// The game's side column: the always-visible play bar and the panels behind the tabs.
import {useEffect, useLayoutEffect, useRef, useState} from 'react';
import {auth} from '../api';
import {C, PLAYERS} from '../game/draw';
import type {GameCtl} from '../game/game';
import {makeGif} from '../game/gif';
import {beep, soundPrefs} from '../game/sound';
import {Stone, useCtl} from './common';

// a seat's byo-yomi clock as of the last state: main time, or the periods left of the period length
function seatClock(gs: any, seat: any) {
  if (gs.status !== 'playing') return '–';
  return seat.mainLeftMs > 0 ? fmtClock(seat.mainLeftMs) : seat.periodsLeft + ' × ' + fmtClock(gs.byoyomiMs);
}
function fmtClock(ms: number) { const s = Math.max(0, Math.ceil(ms / 1000)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }

function Status({g}: {g: GameCtl}) {
  const gs = g.gs, cur = g.cur; if (!gs) return <div className="status" />;
  if (!g.root) return <div className="status"><div className="slot big">Waiting to start</div><div className="slot muted">{gs.seats.filter((s: any) => s.controller !== 'open').length} of {gs.seats.length} seats planned or taken. Empty open seats become bots at the start.</div></div>;
  const s = cur.state, K = g.K, G = g.G; let L1: React.ReactNode, L2 = '';
  if (cur === g.root) { L1 = 'Empty board'; L2 = K + ' players on ' + G.N + '×' + G.N + ', ko rule ' + (s.koOn ? 'on' : 'off') + '.'; }
  else { const i = cur.info || {}, bits: string[] = [];
    if (cur.rid) bits.push('review move by ' + cur.author + ', kept for everyone in this game (not part of the game)'); else if (cur.local) bits.push('your variation (not part of the game)');
    if (i.source === 'deadline') bits.push('clock ran out: board unchanged'); if (i.source === 'person') bits.push('played by ' + g.seatName(cur.player));
    if (i.source === 'bot') bits.push('played by the server bot'); if (i.source === 'autopilot') bits.push('played by autopilot for ' + g.seatName(cur.player));
    if (i.guard) bits.push('played on instead of passing to remove dead stones');
    if (i.search && i.search.plannedMs) bits.push('thought ' + (i.search.ms / 1000).toFixed(1) + ' s of a planned ' + (i.search.plannedMs / 1000).toFixed(1) + ' s (' + ({settled: 'stopped early: the choice was settled', planned: 'stopped at the plan', limit: 'a close call, stretched to the limit', single: 'only one move'} as Record<string, string>)[i.search.stop] + ')');
    if (i.captured && i.victims) bits.push('captured ' + Object.keys(i.victims).map(v => i.victims[v] + ' ' + PLAYERS[+v].name).join(', '));
    if (i.suicide) bits.push('suicide, lost ' + i.suicide); if (i.resigned) bits.push('resigned'); if (i.source === 'resigned') bits.push('automatic pass after resigning');
    L1 = <span>Move {cur.depth} · <Stone p={cur.player} /> {g.seatName(cur.player)} {g.coord(cur.move)}</span>; L2 = bits.join(' · '); }
  let L3: React.ReactNode;
  if (cur === g.live && gs.status === 'finished') L3 = <span className="over">Game over ({gs.endReason}). Winner: {gs.winners.map((w: number) => g.seatName(w)).join(' and ')}.</span>;
  else if (isTerminal(G, s)) L3 = <span className="over">This line is over.</span>;
  else { const w: string[] = []; let n = 0; for (let q = 1; q <= K; q++) { if (s.pm & (1 << q)) n++; else if (!(s.out & (1 << q))) w.push(g.seatName(q)); }
    L3 = <span><Stone p={s.toMove} /> <b>{g.seatName(s.toMove)}</b>{cur === g.live && g.myLiveTurn() ? ' — your move' : ' to play'}{n ? ' · ' + n + ' passed; still to pass: ' + w.join(', ') : ''}</span>; }
  let L4: React.ReactNode = g.flashMsg ? <span className="danger">{g.flashMsg}</span> : cur !== g.live ? <button type="button" className="linkish" onClick={() => g.toLive()}>Back to the live game (move {g.live.depth})</button> : null;
  if (g.mismatch) L4 = <span className="danger">The replayed board differs from the server board; reload the page.</span>;
  return <div className="status"><div className="slot big">{L1}</div><div className="slot muted">{L2 || ' '}</div><div className="slot">{L3}</div><div className="slot">{L4 || ' '}</div></div>;
}

export function PlayBar({g}: {g: GameCtl}) {
  useCtl(g); const gs = g.gs;
  const [, tick] = useState(0); const [armed, setArmed] = useState(false);
  const warned = useRef(-1), lastTick = useRef(0);
  useEffect(() => { const t = setInterval(() => tick(x => x + 1), 200); return () => clearInterval(t); }, []);
  useEffect(() => { if (!armed) return; const t = setTimeout(() => setArmed(false), 3000); return () => clearTimeout(t); }, [armed]);
  let clock = '–:––', pct = 0, warn = false, idle = true;
  if (gs && gs.status === 'playing') {
    // every seat has the same byo-yomi clock: main time, then periods
    const seat = gs.seats[gs.toMove - 1], botTurn = seat.controller !== 'person', inMain = seat.mainLeftMs > 0;
    const limit = inMain ? gs.mainTimeMs : gs.byoyomiMs, left = gs.remainingMs - (performance.now() - gs.stateAt);
    const mine = gs.toMove === g.mySeat() && !botTurn; warn = !botTurn && left <= 10000; idle = false;
    clock = inMain ? fmtClock(left) : 'byo-yomi ' + fmtClock(left) + ' × ' + seat.periodsLeft; pct = Math.min(100, Math.max(0, (1 - left / limit) * 100));
    if (mine && warn && warned.current !== gs.moveNo) { warned.current = gs.moveNo; beep(880, 140); beep(880, 140, .22); }
    const sec = Math.ceil(left / 1000); if (mine && sec <= 5 && sec > 0 && sec !== lastTick.current) { lastTick.current = sec; beep(1320, 60); }
  }
  let think = '';
  if (gs) { if (g.think) { const l = g.think.live; think = 'Your local search' + (l ? ' · ' + l.iters.toLocaleString() + ' playouts' : '') + ' · ' + (g.think.dead / 1000) + ' s'; }
    else if (gs.status !== 'playing') think = gs.status === 'finished' ? 'Game over.' : 'Waiting for the creator to start.';
    else { const seat = gs.seats[gs.toMove - 1]; think = seat.controller === 'person' ? (gs.toMove === g.mySeat() ? 'Your move: click a point, or Pass.' : seat.player + ' to move.') : (seat.controller === 'autopilot' ? 'Autopilot is thinking for ' + seat.player + '.' : seat.player + ' (server bot) is thinking.'); } }
  const myTurn = g.myLiveTurn(), me = g.mySeat(), playing = gs?.status === 'playing';
  return (
    <section className="box playbar" aria-live="polite"><h3>Now</h3>
      <Status g={g} />
      <div className="row">
        {gs && gs.status === 'open' && gs.creator === auth.identity ? <button type="button" className="primary gv-start" onClick={() => void g.act('start_game', {}, 'Game started. Bots took the empty seats.')}>Start game (bots fill empty seats)</button> : null}
        <button type="button" className="gv-pass" disabled={!g.canPassHere()} title={myTurn ? 'Pass (P)' : 'Pass in this variation, for the seat to move (P)'} onClick={() => g.pass()}>Pass</button>
        <button type="button" className="gv-resign" disabled={!myTurn} onClick={() => { if (!armed) { setArmed(true); return; } setArmed(false); g.resign(); }}>{armed ? 'Confirm resign' : 'Resign'}</button>
        {playing && me ? <button type="button" className="gv-autopilot" onClick={() => void g.act('set_autopilot', {on: g.myControl() !== 'autopilot'})}>{g.myControl() === 'autopilot' ? 'Take my seat back' : 'Let a bot play for me'}</button> : null}
      </div>
      <div className={'bar' + (warn ? ' warn' : '')} aria-hidden="true"><i style={{width: pct + '%'}} /></div>
      <div className="thinkrow"><div className={'clock' + (idle ? ' idle' : '') + (warn ? ' warn' : '')} aria-label="Turn clock">{clock}</div><div className="small muted gv-think">{think}</div></div>
      <div className="row">
        <label className="inline"><input type="checkbox" checked={g.territory} onChange={e => { g.territory = e.target.checked; g.emit(); }} /> Territory</label>
        <label className="inline"><input type="checkbox" checked={g.heat} onChange={e => { g.heat = e.target.checked; g.emit(); }} /> Search heat</label>
        <label className="inline"><input type="checkbox" defaultChecked={soundPrefs.on} onChange={e => { soundPrefs.on = e.target.checked; }} /> Sound</label>
      </div>
    </section>
  );
}

function Timeline({g}: {g: GameCtl}) {
  const ref = useRef<HTMLCanvasElement>(null), nodes = useRef<any[]>([]), [w, setW] = useState(0);
  useEffect(() => { const c = ref.current; if (!c) return; const ro = new ResizeObserver(() => setW(c.getBoundingClientRect().width)); ro.observe(c); return () => ro.disconnect(); }, []);
  useLayoutEffect(() => {
    const tl = ref.current; if (!tl || !w) return; const h = 150, dpr = window.devicePixelRatio || 1;
    tl.width = Math.round(w * dpr); tl.height = Math.round(h * dpr); const x = tl.getContext('2d'); if (!x) return; x.setTransform(dpr, 0, 0, dpr, 0, 0); x.fillStyle = C.bg; x.fillRect(0, 0, w, h);
    if (!g.root) { nodes.current = []; return; }
    const line: any[] = []; for (let p = g.cur; p; p = p.parent) line.unshift(p); const ci = line.length - 1; for (let q = g.cur; q.children.length;) { q = q.children[q.main]; line.push(q); } nodes.current = line;
    const vals = line.map(n => g.mctsView(n)); let lo = 0, hi = 0; vals.forEach(v => { if (v) v.proj.forEach((s: number) => { lo = Math.min(lo, s); hi = Math.max(hi, s); }); });
    const L = 34, R = 8, T = 10, B = 22, span = Math.max(1, line.length - 1); if (hi - lo < 4) { hi += 2; lo -= 2; }
    const X = (i: number) => L + (w - L - R) * i / span, Y = (s: number) => T + (h - T - B) * (hi - s) / (hi - lo);
    x.font = '13px ui-monospace, monospace'; x.fillStyle = C.muted; x.textBaseline = 'middle'; x.textAlign = 'right';
    x.fillText(String(Math.round(hi)), L - 6, Y(hi)); x.fillText(String(Math.round(lo)), L - 6, Y(lo)); x.strokeStyle = C.rule; x.lineWidth = 1; x.beginPath(); x.moveTo(L, Y(0)); x.lineTo(w - R, Y(0)); x.stroke(); x.fillText('0', L - 6, Y(0));
    x.textAlign = 'left'; x.textBaseline = 'alphabetic'; x.fillText('move 0', L, h - 5); x.textAlign = 'right'; x.fillText('move ' + (line.length - 1), w - R, h - 5);
    for (let pl = 1; pl <= g.K; pl++) { x.strokeStyle = pl === 1 ? PLAYERS[1].rim : PLAYERS[pl].fill; x.lineWidth = 2.5; x.setLineDash(pl === 1 ? [5, 4] : []);
      for (let seg = 0; seg < 2; seg++) { x.globalAlpha = seg ? .35 : 1; x.beginPath(); let on = false;
        for (let i = seg ? ci : 0; i <= (seg ? line.length - 1 : ci); i++) { const v = vals[i]; if (!v) { on = false; continue; } const px = X(i), py = Y(v.proj[pl - 1]); if (on) x.lineTo(px, py); else { x.moveTo(px, py); on = true; } } x.stroke(); }
      x.globalAlpha = 1; x.setLineDash([]); }
    x.strokeStyle = C.accent; x.lineWidth = 2; x.beginPath(); x.moveTo(X(ci), T - 4); x.lineTo(X(ci), h - B + 4); x.stroke();
  });
  const click = (e: React.MouseEvent) => { const list = nodes.current; if (!list.length || !ref.current) return; const r = ref.current.getBoundingClientRect(), L = 34, R = 8, span = Math.max(1, list.length - 1);
    let i = Math.round((e.clientX - r.left - L) / ((r.width - L - R) / span)); i = Math.max(0, Math.min(list.length - 1, i)); g.jump(list[i]); };
  return <canvas ref={ref} className="timeline" aria-label="Projected final score per seat along the viewed line; click to jump to a move" onClick={click} />;
}

export function ScoresPanel({g}: {g: GameCtl}) {
  useCtl(g); const gs = g.gs;
  if (!gs || !g.root) return <><table className="scores" /><div className="small muted">Scores appear when the game starts.</div><Timeline g={g} /></>;
  const cur = g.cur, s = cur.state, K = g.K, G = g.G, sc = scoreState(G, s, false), bd = g.bowls(cur), vw = g.mctsView(cur), tA = g.teamsActive(), over = isTerminal(G, s);
  const totals: {t: number; seats: number[]; score: number}[] = [];
  if (tA) for (let p = 1; p <= K; p++) { const t = g.teamOf(p); let e = totals.find(x => x.t === t); if (!e) { e = {t, seats: [], score: 0}; totals.push(e); } e.seats.push(p); e.score += sc.scores[p]; }
  return (
    <>
      <table className="scores"><tbody>
        <tr>{['Player', 'Terr.', 'Bowl', 'Score', 'Proj.', 'Outlook', 'Clock'].map(t => <th key={t}>{t}</th>)}</tr>
        {Array.from({length: K}, (_, i) => i + 1).map(p => { const seat = gs.seats[p - 1], out = !!(s.out & (1 << p)), toPlay = p === s.toMove && !over;
          return <tr key={p} className={toPlay ? 'tomove' : ''}>
            <td className="name"><Stone p={p} /> {seat.player || PLAYERS[p].name}{seat.controller === 'bot' ? <span className="team">bot</span> : null}{seat.controller === 'autopilot' ? <span className="team">autopilot</span> : null}{out ? <span className="team">resigned</span> : null}{tA ? <span className="team">T{g.teamOf(p)}</span> : null}{toPlay ? <span className="tag">to play</span> : null}</td>
            <td>{sc.terr[p]}</td>
            <td><b>{s.losses[p]}</b><div className="bks">{Array.from({length: K}, (_, j) => j + 1).filter(c => bd[p][c]).map(c => <span key={c} className="bk" title={c === p ? 'lost to own suicide' : 'captured by ' + g.seatName(c)}>{c === p ? 'self' : <Stone p={c} size={14} />}{bd[p][c]}</span>)}</div></td>
            <td><b>{sc.scores[p]}</b></td><td>{vw ? vw.proj[p - 1].toFixed(1) : '–'}</td><td>{vw ? Math.round(vw.q[p - 1] * 100) + '%' : '–'}</td><td className="clock-cell">{seatClock(gs, seat)}</td>
          </tr>; })}
        <tr><td colSpan={7} className="small muted left">{tA ? <>Team totals: {totals.map(t => <span key={t.t} className="teamtotal">T{t.t} {t.seats.map(p => <Stone key={p} p={p} size={16} />)} <b>{t.score}</b></span>)}</> : 'No teams: everyone plays alone.'}</td></tr>
      </tbody></table>
      <div className="small muted">{!vw ? 'Proj. and Outlook appear for positions a search has weighed: every bot move, or your own analysis.' :
        vw.src === 'here' ? (vw.server ? 'Proj. and Outlook: the server bot\'s search at this position (' : 'Proj. and Outlook: your local search at this position (') + vw.n.toLocaleString() + ' playouts' + (vw.live ? ', running' : '') + ').' :
        'Proj. and Outlook: what the search expected when it weighed this move (' + vw.n.toLocaleString() + ' playouts through it).'}</div>
      <Timeline g={g} />
    </>
  );
}

export function SearchPanel({g}: {g: GameCtl}) {
  useCtl(g); const cur = g.cur;
  let d = g.heatFor(cur) || (cur && cur.search), note = '';
  if ((!d || !d.top || !d.top.length) && cur && cur.parent && cur.parent.search) { d = cur.parent.search; note = 'The search that chose the move just played, at the position before it:'; }
  const at = note ? cur.parent : cur, can = !!g.root && g.analysisAllowed(), over = !g.root || isTerminal(g.G, cur.state), me = g.mySeat(), playing = g.gs?.status === 'playing';
  return (
    <>
      <div className="cands">
        <div className="cand head"><span>Move</span><span>Visits</span><span>Share</span><span>Reward</span></div>
        {!d || !d.top || !d.top.length ? <div className="muted small pad">Candidates appear here for every bot move, and for your own analysis when it is allowed.</div> : <>
          {note ? <div className="muted small">{note}</div> : null}
          {d.top.slice(0, 8).map((c: any, i: number) => { const sh = c.n / d.total;
            return <button key={i} type="button" className={'cand' + (note && c.move === cur.move ? ' chosen' : '')} onClick={() => { if (at !== cur) g.go(at); g.tryPlay(at, c.move); }}>
              <span>{g.coord(c.move)}</span><span>{Math.round(sh * 100)}%</span><span className="bar"><i style={{width: (sh * 100) + '%'}} /></span><span>{Math.round(c.q * 100)}%</span></button>; })}
        </>}
      </div>
      <div className="row">
        <button type="button" className="gv-move" disabled={!can || !!g.think || over} onClick={() => g.localSearch(g.cur, true)}>Computer move</button>
        <button type="button" className="gv-analyze" disabled={!can || !!g.think || over} onClick={() => g.localSearch(g.cur, false)}>Analyze here</button>
        <button type="button" className={'gv-auto' + (g.autoplay ? ' on' : '')} disabled={!can} onClick={() => g.toggleAutoplay()}>{g.autoplay ? 'Stop autoplay' : 'Autoplay variation'}</button>
      </div>
      <p className="small muted">{!g.root ? '' : can ? 'Analysis runs in your browser only and never changes the game.' : (me && playing ? 'You are seated: step through the game freely; variations and local search unlock when the game ends.' : '')}</p>
    </>
  );
}

export function SeatsPanel({g}: {g: GameCtl}) {
  useCtl(g); const gs = g.gs; const [mergeWith, setMergeWith] = useState(0);
  if (!gs) return null;
  const me = g.mySeat(), creator = gs.creator === auth.identity, open = gs.status === 'open', n = gs.seats.length;
  const myTeam = me ? gs.seats[me - 1].team : 0, others = [...new Set<number>(gs.seats.map((s: any) => s.team))].filter(t => t !== myTeam), target = others.includes(mergeWith) ? mergeWith : others[0];
  return (
    <>
      <div className="roster">
        {gs.seats.map((st: any) => { const p = st.seat; let who = st.player || (st.controller === 'bot' ? 'Bot' : 'Open seat'); if (st.controller === 'open' && open) who = 'Open seat · a bot if still empty at the start';
          return <div key={p} className="rrow" data-seat={p}>
            <Stone p={p} /><span className="who">{who}{st.controller === 'autopilot' ? ' (autopilot)' : ''} <span className="muted small">{PLAYERS[p].name}</span></span>
            {open && creator && st.controller !== 'person'
              ? <select className="plan-ctl" aria-label={'Seat ' + p + ' controller'} value={st.controller === 'bot' ? 'bot' : 'open'} onChange={e => void g.act('set_seat_plan', {seat: p, controller: e.target.value, team: st.team})}><option value="open">Person</option><option value="bot">Bot</option></select>
              : <span className="team">{st.controller === 'person' || st.controller === 'autopilot' ? 'person' : st.controller}</span>}
            {open && creator
              ? <select className="plan-team" aria-label={'Seat ' + p + ' team'} value={String(st.team)} onChange={e => void g.act('set_seat_plan', {seat: p, controller: st.controller === 'bot' ? 'bot' : 'open', team: +e.target.value})}>{Array.from({length: n}, (_, t) => <option key={t} value={String(t + 1)}>Team {t + 1}</option>)}</select>
              : <span className="team">T{st.team}</span>}
            {open && st.controller === 'open' && !me ? <button type="button" onClick={() => void g.act('take_seat', {seat: p}, 'You took seat ' + p + '.')}>Sit here</button> : null}
            {open && me === p ? <button type="button" onClick={() => void g.act('leave_seat', {}, 'You left your seat.')}>Leave</button> : null}
          </div>; })}
      </div>
      <div className="merges">
        {gs.status === 'playing' && me && others.length ? <div className="row"><span>Merge my team with</span>
          <select aria-label="Team to merge with" value={String(target)} onChange={e => setMergeWith(+e.target.value)}>{others.map(t => <option key={t} value={String(t)}>Team {t} ({gs.seats.filter((s: any) => s.team === t).map((s: any) => s.player).join(', ')})</option>)}</select>
          <button type="button" onClick={() => void g.act('propose_merge', {otherTeam: target}, 'Proposal sent. Everyone on both teams must accept.')}>Propose</button></div> : null}
        {(gs.proposals || []).map((pr: any) => { const mine = pr.waitingFor.includes(auth.identity);
          return <div key={pr.proposalId} className={mine ? 'proposal mine' : 'proposal'}>
            <div>Team {pr.teamA} + Team {pr.teamB}, proposed by {pr.proposer}</div>
            <div className="small muted">Accepted: {pr.acceptedBy.join(', ') || 'nobody'} · waiting for: {pr.waitingFor.join(', ') || 'nobody'}</div>
            {mine ? <div className="row"><button type="button" onClick={() => void g.act('respond_merge', {proposalId: pr.proposalId, accept: true})}>Accept merge</button><button type="button" onClick={() => void g.act('respond_merge', {proposalId: pr.proposalId, accept: false})}>Decline</button></div> : null}
          </div>; })}
        {!(gs.status === 'playing' && me && others.length) && !(gs.proposals || []).length ? <p className="small muted">{gs.status === 'playing' ? (me ? 'No pending merges.' : 'Seated people can propose merging teams; every person on both teams must accept.') : 'Teams can merge once the game is playing. Merges are permanent.'}</p> : null}
      </div>
    </>
  );
}

export function GifPanel({g}: {g: GameCtl}) {
  useCtl(g); const [delay, setDelay] = useState(450), [size, setSize] = useState(480), [busy, setBusy] = useState(false), [out, setOut] = useState<any>(null);
  const run = async () => { setBusy(true); setOut({text: 'Rendering…'}); try { setOut(await makeGif(g, size, delay)); } catch (e: any) { setOut({error: 'GIF failed: ' + (e?.message || e)}); } setBusy(false); };
  return (
    <>
      <div className="grid2">
        <label>Frame delay<select value={delay} onChange={e => setDelay(+e.target.value)}><option value={250}>0.25 s</option><option value={450}>0.45 s</option><option value={700}>0.7 s</option><option value={1000}>1 s</option></select></label>
        <label>Size<select value={size} onChange={e => setSize(+e.target.value)}><option value={360}>360 px</option><option value={480}>480 px</option><option value={640}>640 px</option></select></label>
      </div>
      <button type="button" disabled={!g.root || busy} onClick={() => void run()}>Make GIF up to this move</button>
      <div className="gifout">{!out ? null : out.text ? <div className="small muted">{out.text}</div> : out.error ? <div className="danger">{out.error}</div> :
        <><img alt={'Animated replay to move ' + out.depth} src={out.url} /><a href={out.url} download={out.name} className="button">Save {out.name}</a><span className="small muted"> {out.frames} frames · {out.kb} KB</span></>}</div>
    </>
  );
}
