// Requirement refs: property:Lab-style viewer; property:Analysis is local; property:game_state reflects
// the authoritative game; grammar:set_seat_plan, take_seat, leave_seat, start_game, set_autopilot,
// play_move, propose_merge, respond_merge, game_state; proof:analysis never leaks into the game;
// proof:pointer preview never misleads.
//
// One open game: the N-Player Go Lab game tree driven by server state. The main line mirrors
// GameState.moves (server nodes). Variations and local searches are client-only nodes
// (local = true) that are never sent to the server. One controller per open game tab.
import {api, auth, feedback, nextID} from '../api';
import {beep, moveSound} from './sound';
import {COLS, PLAYERS} from './draw';

export class GameCtl {
  readonly gameId: string;
  gs: any = null; records: any[] = []; G: any = null; K = 0;
  root: any = null; cur: any = null; live: any = null;
  private byId = new Map<number, any>(); private nextNode = 1;
  mismatch = false; flashMsg = ''; private flashT = 0;
  think: any = null; autoplay = false; private worker: Worker | null = null; private searchId = 0;
  territory = true; heat = true; hoverPt = -1;
  private busy = false; private timer = 0; private alive = true; active = false;
  private listeners = new Set<() => void>(); version = 0;

  constructor(gameId: string) { this.gameId = gameId; }

  // ---------- subscription (React re-renders on emit) ----------
  subscribe = (l: () => void) => { this.listeners.add(l); return () => void this.listeners.delete(l); };
  getVersion = () => this.version;
  emit() { this.version++; this.listeners.forEach(l => l()); }

  start() { this.alive = true; void this.refresh().then(() => this.schedule()); }
  stop() { this.alive = false; clearTimeout(this.timer); this.stopThinking(); }
  setActive(on: boolean) { if (this.active === on) return; this.active = on; if (on) { void this.refresh(); this.schedule(); } }

  // ---------- facts about me and this game ----------
  mySeat(): number { const gs = this.gs; if (!gs) return 0; const s = gs.seats.find((x: any) => x.player === auth.identity && (x.controller === 'person' || x.controller === 'autopilot')); return s ? s.seat : 0; }
  myControl(): string { const n = this.mySeat(); return n ? this.gs.seats[n - 1].controller : ''; }
  myLiveTurn(): boolean { const gs = this.gs; return !!gs && gs.status === 'playing' && this.mySeat() === gs.toMove && this.myControl() === 'person'; }
  // Seated people may branch only after the game finishes (property:Analysis is local).
  analysisAllowed(): boolean { const gs = this.gs; return !!gs && gs.status !== 'open' && !(this.mySeat() > 0 && gs.status === 'playing'); }
  teamOf(p: number) { return this.gs ? this.gs.seats[p - 1].team : p; }
  teamArray() { const a = [0]; for (let i = 1; i <= this.K; i++) a.push(this.teamOf(i)); return a; }
  teamsActive() { if (!this.gs) return false; const seen: Record<number, number> = {}; for (let i = 1; i <= this.K; i++) { const t = this.teamOf(i); if (seen[t]) return true; seen[t] = 1; } return false; }
  seatName(p: number) { const gs = this.gs; return gs && gs.seats[p - 1] && gs.seats[p - 1].player ? gs.seats[p - 1].player : PLAYERS[p].name; }
  ptOf(x: number, y: number) { return (y + 1) * this.G.W + x + 1; }
  coord(m: number | null) { if (m === null || m === undefined) return ''; if (m === RESIGN) return 'Resign'; if (m === TIMEOUT) return 'Timeout'; if (m < 0) return 'Pass'; const G = this.G, x = m % G.W - 1, y = (m / G.W | 0) - 1; return COLS[x] + (G.N - y); }
  needsMe(): boolean { return this.myLiveTurn() || (this.gs?.proposals || []).some((p: any) => p.waitingFor.includes(auth.identity)); }

  // ---------- server sync ----------
  private mkNode(parent: any, move: number | null, state: any, info: any, player: number, local: boolean) {
    const n = {id: this.nextNode++, parent, children: [] as any[], main: 0, move, player: player || 0, state, key: stateKey(this.G, state), info: info || null, search: null as any, depth: parent ? parent.depth + 1 : 0, local, server: false, rec: null as any};
    this.byId.set(n.id, n); return n;
  }
  private moveOf(rec: any) { if (rec.kind === 'place') return (rec.y + 1) * this.G.W + rec.x + 1; if (rec.kind === 'resign') return RESIGN; if (rec.kind === 'timeout') return TIMEOUT; return -1; }
  private summaryToLab(sum: any) {
    const top = (sum.candidates || []).map((c: any) => ({move: c.kind === 'pass' ? -1 : this.ptOf(c.x, c.y), n: c.visits, q: c.rewardPermille / 1000, qs: c.outlookPermille.map((v: number) => v / 1000), proj: c.projMilli.map((v: number) => v / 1000)}));
    return {top, total: sum.playouts, iters: sum.playouts, ms: sum.ms, rootQ: sum.rootOutlookPermille.map((v: number) => v / 1000), proj: sum.rootProjMilli.map((v: number) => v / 1000), guard: sum.guard, server: true};
  }
  private ensureTree() {
    const gs = this.gs; if (this.root || !gs || gs.status === 'open') return;
    this.K = gs.seats.length; this.G = makeGeom(gs.boardSize);
    this.root = this.mkNode(null, null, newState(this.G, this.K, gs.koOn), null, 0, false); this.root.server = true; this.cur = this.live = this.root;
  }
  private syncMoves(recs: any[]) {
    for (const rec of recs) {
      if (rec.moveNo !== this.records.length) continue; // duplicates or gaps are ignored; the next poll asks again
      this.records.push(rec);
      const m = this.moveOf(rec), parent = this.live;
      if (rec.search) parent.search = this.summaryToLab(rec.search);
      let ch = parent.children.find((c: any) => c.move === m && !c.server);
      if (ch && ch.player === parent.state.toMove) ch.local = false;
      else { const s = cloneState(parent.state), player = s.toMove, res = play(this.G, s, m); ch = this.mkNode(parent, m, s, res, player, false); parent.children.push(ch); }
      ch.server = true; ch.rec = rec; ch.info.source = rec.source; if (rec.search && rec.search.guard) ch.info.guard = true;
      parent.main = parent.children.indexOf(ch);
      const follow = this.cur === this.live; this.live = ch; if (follow) { this.cur = ch; if (this.active) moveSound(ch); }
    }
    const gs = this.gs;
    if (gs && gs.cells.length && this.records.length === gs.moveNo) { const cells = this.G.pts.map((p: number) => this.live.state.cells[p]); this.mismatch = cells.some((v: number, i: number) => v !== gs.cells[i]); }
  }
  async refresh() {
    if (this.busy || !this.alive) return; this.busy = true;
    try {
      const st = await api('game_state', {gameId: this.gameId, sinceMove: this.records.length, requestId: nextID()});
      if (!this.alive || st.gameId !== this.gameId) return; // a response for another game never lands here
      const prev = this.gs && this.gs.status; this.gs = st; this.ensureTree(); if (this.root) this.syncMoves(st.moves || []);
      this.gs.stateAt = performance.now();
      if (prev !== st.status && st.status === 'finished') beep(523, 300);
      this.emit();
    } catch (e: any) { if (this.alive) feedback(e.message, true); }
    finally { this.busy = false; }
  }
  private schedule() {
    clearTimeout(this.timer); if (!this.alive) return;
    const playing = this.gs && this.gs.status === 'playing', ms = this.active ? (playing ? 500 : 1500) : (playing ? 2000 : 5000);
    this.timer = window.setTimeout(async () => { if (!document.hidden) await this.refresh(); this.schedule(); }, ms);
  }

  // ---------- actions ----------
  async act(action: string, payload: Record<string, unknown> = {}, okText = '') {
    try { await api(action, {gameId: this.gameId, ...payload, requestId: nextID()}); if (okText) feedback(okText); await this.refresh(); }
    catch (e: any) { feedback(e.message, true); }
  }
  flash(t: string) { this.flashMsg = t; clearTimeout(this.flashT); this.flashT = window.setTimeout(() => { this.flashMsg = ''; this.emit(); }, 3500); this.emit(); }
  async serverMove(kind: string, m: number) {
    const G = this.G, x = m >= 0 ? m % G.W - 1 : 0, y = m >= 0 ? (m / G.W | 0) - 1 : 0;
    try { await api('play_move', {gameId: this.gameId, moveNo: this.gs.moveNo, kind, x, y, requestId: nextID()}); }
    catch (e: any) { this.flash(e.message); }
    await this.refresh();
  }
  // Pass or resign in the real game on my turn, even while viewing another position: the view
  // jumps back to the live game first, so the move is never made somewhere unseen.
  private notMyTurn() { const gs = this.gs; return !gs || gs.status !== 'playing' ? 'The game is not in progress.' : this.myControl() === 'autopilot' ? 'Autopilot has your seat; take it back first.' : this.mySeat() ? 'It is not your turn.' : 'Only seated players can pass.'; }
  pass() { if (!this.myLiveTurn()) { this.flash(this.notMyTurn()); return; } if (this.cur !== this.live) this.toLive(); void this.serverMove('pass', -1); }
  resign() { if (!this.myLiveTurn()) { this.flash(this.notMyTurn()); return; } if (this.cur !== this.live) this.toLive(); void this.serverMove('resign', RESIGN); }
  tryPlay(node: any, m: number) {
    const G = this.G;
    if (node === this.live && this.myLiveTurn()) { // the real game: only the live position, only on my turn
      if (m >= 0 && node.state.cells[m] !== 0) { this.flash('That point is occupied.'); return; }
      void this.serverMove(m === RESIGN ? 'resign' : m < 0 ? 'pass' : 'place', m); return;
    }
    if (!this.analysisAllowed()) { this.flash(this.gs && this.gs.status === 'playing' && this.mySeat() ? (node === this.live ? 'It is not your turn.' : 'You can step through the game, but variations unlock when it ends.') : 'Variations open once the game starts.'); return; }
    if (isTerminal(G, node.state)) { this.flash('The game is over at this position.'); return; }
    if (!isLegal(G, node.state, m)) { this.flash(node.state.cells[m] ? 'That point is occupied.' : 'Ko: that recapture must wait one round.'); return; }
    if (m >= 0 && node.state.koOn) { const s = cloneState(node.state); play(G, s, m); for (let p = node; p; p = p.parent) if (p.key === stateKey(G, s)) { this.flash('Superko: that recreates an earlier position.'); return; } }
    const ex = node.children.find((c: any) => c.move === m); if (ex) { node.main = node.children.indexOf(ex); this.go(ex); return; }
    const s = cloneState(node.state), player = s.toMove, res = play(G, s, m); res.source = 'local';
    const ch = this.mkNode(node, m, s, res, player, true); node.children.push(ch); node.main = node.children.length - 1; moveSound(ch); this.go(ch);
  }
  clickPoint(m: number) {
    if (!this.root) return; const cur = this.cur;
    const ex = cur.children.find((c: any) => c.move === m); if (ex && !(cur === this.live && this.myLiveTurn())) { cur.main = cur.children.indexOf(ex); this.go(ex); return; }
    this.tryPlay(cur, m);
  }
  // Would a click at m place a stone here? Same predicates as tryPlay: the live position on my own
  // turn, or a variation where analysis is open to me. The preview is drawn locally and sends nothing.
  canPlaceAt(node: any, m: number): boolean {
    if (!this.root || !node || node.state.cells[m] !== 0 || isTerminal(this.G, node.state)) return false;
    if (node === this.live && this.myLiveTurn()) return isLegal(this.G, node.state, m);
    return this.analysisAllowed() && isLegal(this.G, node.state, m);
  }
  setHover(m: number) { if (m !== this.hoverPt) { this.hoverPt = m; this.emit(); } }

  // ---------- local analysis (Lab search worker; never sent to the server) ----------
  stopThinking() { if (this.think) { clearTimeout(this.think.hard); this.think = null; } if (this.worker) { this.worker.terminate(); this.worker = null; } }
  localSearch(node: any, playIt: boolean) {
    const G = this.G, gs = this.gs;
    if (this.think || !this.analysisAllowed() || isTerminal(G, node.state)) return;
    if (!this.worker) { this.worker = new Worker('./search-worker.js'); this.worker.onmessage = e => this.onWorker(e); }
    const id = ++this.searchId, s = node.state, dead = gs.botMs;
    this.think = {id, node, playIt, live: null, t0: performance.now(), dead};
    this.think.hard = window.setTimeout(() => { if (this.think && this.think.id === id) { this.stopThinking(); this.emit(); } }, dead + 2000);
    const hist = []; for (let p = node; p; p = p.parent) hist.push(p.key);
    this.worker.postMessage({cmd: 'search', id, N: G.N, seed: (Math.random() * 2 ** 31) | 0,
      state: {k: s.k, cells: Array.from(s.cells), losses: Array.from(s.losses), toMove: s.toMove, passes: s.passes, ko: s.ko, koColor: s.koColor, koUntil: s.koUntil, moveNo: s.moveNo, hash: s.hash, koOn: s.koOn, out: s.out, pm: s.pm, to: s.to},
      history: hist, params: {budget: Math.max(80, dead * 0.85 - 40), C: gs.exploreMilli / 1000, mode: gs.rewardMode, T: gs.softness, teams: this.teamsActive() ? this.teamArray() : null}});
    this.emit();
  }
  private onWorker(e: MessageEvent) {
    const d = e.data, think = this.think; if (!think || d.id !== think.id) return;
    if (d.type === 'progress') { think.live = d; this.emit(); return; }
    const node = think.node, playIt = think.playIt; clearTimeout(think.hard); this.think = null; node.search = d;
    if (playIt && this.analysisAllowed()) {
      const m = d.move, ex = node.children.find((c: any) => c.move === m);
      if (ex) { node.main = node.children.indexOf(ex); if (this.cur === node) this.cur = ex; }
      else { const s = cloneState(node.state), player = s.toMove, res = play(this.G, s, m); res.source = 'local'; if (d.guard) res.guard = true;
        const ch = this.mkNode(node, m, s, res, player, true); node.children.push(ch); node.main = node.children.length - 1; if (this.cur === node) { moveSound(ch); this.cur = ch; } }
    }
    this.emit();
    const cur = this.cur;
    if (this.autoplay && cur.local && !cur.children.length && !isTerminal(this.G, cur.state)) setTimeout(() => this.localSearch(this.cur, true), 120);
  }
  toggleAutoplay() { this.autoplay = !this.autoplay; this.emit(); if (this.autoplay && this.root && this.analysisAllowed() && !this.think && !isTerminal(this.G, this.cur.state)) this.localSearch(this.cur, true); }
  heatFor(node: any) { if (!node || !this.heat) return null; const t = this.think; if (t && t.node === node && t.live) return t.live; return node.search; }

  // ---------- navigation ----------
  go(n: any) { this.cur = n; this.emit(); }
  back() { if (this.cur?.parent) this.go(this.cur.parent); }
  fwd() { if (this.cur?.children.length) this.go(this.cur.children[this.cur.main]); }
  home() { if (this.root) this.go(this.root); }
  end() { let n = this.cur; if (!n) return; while (n.children.length) n = n.children[n.main]; this.go(n); }
  toLive() { let p = this.live; if (!p) return; while (p.parent) { p.parent.main = p.parent.children.indexOf(p); p = p.parent; } this.go(this.live); }
  sib(d: number) { const p = this.cur?.parent; if (!p) return; const j = p.children.indexOf(this.cur) + d; if (j < 0 || j >= p.children.length) return; p.main = j; this.go(p.children[j]); }
  jump(n: any) { for (let q = n; q.parent; q = q.parent) q.parent.main = q.parent.children.indexOf(q); this.go(n); }
  nodeById(id: number) { return this.byId.get(id); }

  // ---------- derived views ----------
  bowls(node: any) {
    const K = this.K, bd: number[][] = []; for (let i = 0; i <= K; i++) bd.push(new Array(K + 1).fill(0));
    for (let p = node; p && p.parent; p = p.parent) { const inf = p.info; if (!inf) continue; if (inf.victims) for (const v in inf.victims) bd[+v][p.player] += inf.victims[v]; if (inf.suicide) bd[p.player][p.player] += inf.suicide; }
    return bd;
  }
  mctsView(node: any) {
    const t = this.think, own = (t && t.node === node && t.live) || node.search;
    if (own && own.total) return {proj: own.proj, q: own.rootQ, n: own.total, src: 'here', live: !!(t && t.node === node), server: !!own.server};
    const p = node.parent; if (!p) return null; const ps = (t && t.node === p && t.live) || p.search; if (!ps) return null;
    for (const e of ps.top) if (e.move === node.move && e.proj) return {proj: e.proj, q: e.qs, n: e.n, src: 'parent', live: false, server: !!ps.server};
    return null;
  }

  // Read-only probes for the scripted book tour (source/book_tour.py); they change nothing.
  probes() {
    return {point: (x: number, y: number) => (this.live ? this.live.state.cells[this.ptOf(x, y)] : -1), size: () => (this.G ? this.G.N : 9),
      liveMove: () => this.records.length, lastSource: () => (this.records.length ? this.records[this.records.length - 1].source : ''), status: () => (this.gs ? this.gs.status : '')};
  }
}
