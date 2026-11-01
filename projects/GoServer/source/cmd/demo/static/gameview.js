// Requirement refs: property:Lab-style viewer; property:Analysis is local; property:game_state reflects
// the authoritative game; grammar:set_seat_plan, take_seat, leave_seat, start_game, set_autopilot,
// play_move, propose_merge, respond_merge, game_state; proof:analysis never leaks into the game.
//
// The N-Player Go Lab viewer, driven by server state. The main line of the client game tree mirrors
// GameState.moves (server nodes). Variations and local searches are client-only nodes (local = true)
// that are never sent to the server. Uses globals from app.js: $, api, nextID, feedback, identity, session.
'use strict';
const GameView = (() => {
  const PLAYERS = [null,
    {name:'Black', fill:'#0a0a0b', rim:'#d8d2c6', ink:'#ffffff'}, {name:'White', fill:'#f3f1ec', rim:'#6e675c', ink:'#111111'},
    {name:'Red', fill:'#ef4d55', rim:'#140c0c', ink:'#ffffff'}, {name:'Blue', fill:'#4d8dff', rim:'#0b1020', ink:'#ffffff'},
    {name:'Green', fill:'#3cc46e', rim:'#08160d', ink:'#0b1a10'}, {name:'Violet', fill:'#b483ff', rim:'#140c20', ink:'#ffffff'},
    {name:'Orange', fill:'#ff8f3a', rim:'#1c0f05', ink:'#1c0f05'}, {name:'Cyan', fill:'#3ccfdc', rim:'#061618', ink:'#061618'}];
  const C = {bg:'#0e1115', panel:'#161a20', ink:'#f1f3f6', muted:'#b9c2ce', accent:'#ffc94d', board:'#dcb35c', boardInk:'#2a1d08', mark:'#0a4fc4', grid:'#3d2b12', wall:'#434951', wallInk:'#e3e7ed', rule:'#323a46'};
  const COLS = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';

  // ---------- small DOM helper (no inline style attributes: the CSP forbids them) ----------
  function el(tag, props = {}, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === 'class') e.className = v; else if (k === 'text') e.textContent = v; else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (k === 'style') Object.assign(e.style, v); else if (v !== undefined && v !== null && v !== false) e.setAttribute(k, v === true ? '' : v);
    }
    for (const k of kids.flat()) if (k !== null && k !== undefined && k !== false) e.append(k instanceof Node ? k : document.createTextNode(String(k)));
    return e;
  }
  // A stone on a wood tile, as on the board: on the dark page a bare black disc read as a hollow white ring.
  function swatch(i) { return el('span', {class:'sw-tile', title:PLAYERS[i].name, role:'img', 'aria-label':PLAYERS[i].name}, el('span', {class:'sw', style:{background:PLAYERS[i].fill, boxShadow:'0 0 0 1.5px ' + PLAYERS[i].rim}})); }

  // ---------- state ----------
  let gameId = '', epoch = 0, gs = null, records = [], G = null, K = 0, root = null, cur = null, live = null, byId = new Map(), nextNode = 1;
  let busy = false, pollTimer = 0, flashMsg = '', flashT = 0, mismatch = false;
  let worker = null, think = null, autoplay = false, searchId = 0;

  function reset() {
    stopThinking(); autoplay = false;
    gs = null; records = []; G = null; K = 0; root = cur = live = null; byId.clear(); nextNode = 1; mismatch = false;
  }
  function mkNode(parent, move, state, info, player, local) {
    const n = {id:nextNode++, parent, children:[], main:0, move, player:player || 0, state, key:stateKey(G, state), info:info || null, search:null, depth:parent ? parent.depth + 1 : 0, local:!!local, server:false, rec:null};
    byId.set(n.id, n); return n;
  }
  function moveOf(rec) {
    if (rec.kind === 'place') return (rec.y + 1) * G.W + rec.x + 1;
    if (rec.kind === 'resign') return RESIGN; if (rec.kind === 'timeout') return TIMEOUT; return -1;
  }
  function ptOf(x, y) { return (y + 1) * G.W + x + 1; }
  function summaryToLab(sum) {
    const top = (sum.candidates || []).map(c => ({move:c.kind === 'pass' ? -1 : ptOf(c.x, c.y), n:c.visits, q:c.rewardPermille / 1000, qs:c.outlookPermille.map(v => v / 1000), proj:c.projMilli.map(v => v / 1000)}));
    return {top, total:sum.playouts, iters:sum.playouts, ms:sum.ms, rootQ:sum.rootOutlookPermille.map(v => v / 1000), proj:sum.rootProjMilli.map(v => v / 1000), guard:sum.guard, server:true};
  }
  function coord(m) { if (m === null || m === undefined) return ''; if (m === RESIGN) return 'Resign'; if (m === TIMEOUT) return 'Timeout'; if (m < 0) return 'Pass'; const x = m % G.W - 1, y = (m / G.W | 0) - 1; return COLS[x] + (G.N - y); }
  function seatName(p) { return gs && gs.seats[p - 1] && gs.seats[p - 1].player ? gs.seats[p - 1].player : PLAYERS[p].name; }
  function mySeat() { if (!gs) return 0; const s = gs.seats.find(x => x.player === identity && (x.controller === 'person' || x.controller === 'autopilot')); return s ? s.seat : 0; }
  function myControl() { const n = mySeat(); return n ? gs.seats[n - 1].controller : ''; }
  function myLiveTurn() { return gs && gs.status === 'playing' && mySeat() === gs.toMove && myControl() === 'person'; }
  // Requirement refs: property:Analysis is local — seated people may branch only after the game finishes.
  function analysisAllowed() { return gs && gs.status !== 'open' && !(mySeat() > 0 && gs.status === 'playing'); }
  function teamOf(p) { return gs ? gs.seats[p - 1].team : p; }
  function teamArray() { const a = [0]; for (let i = 1; i <= K; i++) a.push(teamOf(i)); return a; }
  function teamsActive() { if (!gs) return false; const seen = {}; for (let i = 1; i <= K; i++) { const t = teamOf(i); if (seen[t]) return true; seen[t] = 1; } return false; }

  // ---------- server sync ----------
  function ensureTree() {
    if (root || !gs || gs.status === 'open') return;
    K = gs.seats.length; G = makeGeom(gs.boardSize);
    root = mkNode(null, null, newState(G, K, gs.koOn), null, 0, false); root.server = true; cur = live = root;
  }
  function syncMoves(recs) {
    for (const rec of recs) {
      if (rec.moveNo !== records.length) continue; // duplicates or gaps are ignored; the next poll asks again
      records.push(rec);
      const m = moveOf(rec), parent = live;
      if (rec.search) parent.search = summaryToLab(rec.search);
      let ch = parent.children.find(c => c.move === m && !c.server);
      if (ch && ch.player === parent.state.toMove) { ch.local = false; }
      else {
        const s = cloneState(parent.state), player = s.toMove, res = play(G, s, m);
        ch = mkNode(parent, m, s, res, player, false); parent.children.push(ch);
      }
      ch.server = true; ch.rec = rec; ch.info.source = rec.source; if (rec.search && rec.search.guard) ch.info.guard = true;
      parent.main = parent.children.indexOf(ch);
      const follow = cur === live; live = ch; if (follow) cur = ch;
      if (follow) moveSound(ch);
    }
    if (gs && gs.cells.length && records.length === gs.moveNo) {
      const cells = G.pts.map(p => live.state.cells[p]);
      mismatch = cells.some((v, i) => v !== gs.cells[i]);
    }
  }
  async function refresh() {
    if (!gameId || busy) return; busy = true; const e = epoch;
    try {
      const st = await api('game_state', {gameId, sinceMove:records.length, requestId:nextID()});
      if (e !== epoch || st.gameId !== gameId) return;
      const prevStatus = gs && gs.status; gs = st; ensureTree(); if (root) syncMoves(st.moves || []);
      gs.stateAt = performance.now();
      if (prevStatus !== gs.status && gs.status === 'finished') beep(523, 300);
      if (!prevStatus && gs.status === 'open') showTab('seats'); // before the start the seat plan is what matters
      render();
    } catch (error) { feedback(error.message, true); }
    finally { busy = false; }
  }
  function schedule() { clearTimeout(pollTimer); if (!gameId) return; pollTimer = setTimeout(async () => { if (!document.hidden) await refresh(); schedule(); }, gs && gs.status === 'playing' ? 500 : 1500); }

  // ---------- actions ----------
  async function act(action, payload, okText) {
    try { await api(action, {gameId, ...payload, requestId:nextID()}); if (okText) feedback(okText); await refresh(); }
    catch (error) { feedback(error.message, true); }
  }
  function flash(t) { flashMsg = t; clearTimeout(flashT); flashT = setTimeout(() => { flashMsg = ''; renderStatus(); }, 3500); renderStatus(); }
  async function serverMove(kind, m) {
    const x = m >= 0 ? m % G.W - 1 : 0, y = m >= 0 ? (m / G.W | 0) - 1 : 0;
    try { await api('play_move', {gameId, moveNo:gs.moveNo, kind, x, y, requestId:nextID()}); }
    catch (error) { flash(error.message); }
    await refresh();
  }
  function tryPlay(node, m) {
    if (node === live && myLiveTurn()) { // the real game: only the live position, only on my turn
      if (m >= 0 && node.state.cells[m] !== 0) { flash('That point is occupied.'); return; }
      void serverMove(m === RESIGN ? 'resign' : m < 0 ? 'pass' : 'place', m); return;
    }
    if (!analysisAllowed()) { flash(gs && gs.status === 'playing' && mySeat() ? (node === live ? 'It is not your turn.' : 'You can step through the game, but variations unlock when it ends.') : 'Variations open once the game starts.'); return; }
    if (isTerminal(G, node.state)) { flash('The game is over at this position.'); return; }
    if (!isLegal(G, node.state, m)) { flash(node.state.cells[m] ? 'That point is occupied.' : 'Ko: that recapture must wait one round.'); return; }
    if (m >= 0 && node.state.koOn) { const s = cloneState(node.state); play(G, s, m); for (let p = node; p; p = p.parent) if (p.key === stateKey(G, s)) { flash('Superko: that recreates an earlier position.'); return; } }
    const ex = node.children.find(c => c.move === m); if (ex) { node.main = node.children.indexOf(ex); go(ex); return; }
    const s = cloneState(node.state), player = s.toMove, res = play(G, s, m); res.source = 'local';
    const ch = mkNode(node, m, s, res, player, true); node.children.push(ch); node.main = node.children.length - 1; moveSound(ch); go(ch);
  }

  // ---------- local analysis (Lab search worker; never sent to the server) ----------
  function stopThinking() { if (think) { clearTimeout(think.hard); think = null; } if (worker) { worker.terminate(); worker = null; } }
  function ensureWorker() { if (!worker) { worker = new Worker('./search-worker.js'); worker.onmessage = onWorker; } }
  function localSearch(node, playIt) {
    if (think || !analysisAllowed() || isTerminal(G, node.state)) return;
    ensureWorker(); const id = ++searchId, s = node.state, dead = gs.botMs;
    think = {id, node, playIt, live:null, t0:performance.now(), dead};
    think.hard = setTimeout(() => { if (think && think.id === id) { stopThinking(); render(); } }, dead + 2000);
    const hist = []; for (let p = node; p; p = p.parent) hist.push(p.key);
    worker.postMessage({cmd:'search', id, N:G.N, seed:(Math.random() * 2 ** 31) | 0,
      state:{k:s.k, cells:Array.from(s.cells), losses:Array.from(s.losses), toMove:s.toMove, passes:s.passes, ko:s.ko, koColor:s.koColor, koUntil:s.koUntil, moveNo:s.moveNo, hash:s.hash, koOn:s.koOn, out:s.out, pm:s.pm, to:s.to},
      history:hist, params:{budget:Math.max(80, dead * 0.85 - 40), C:gs.exploreMilli / 1000, mode:gs.rewardMode, T:gs.softness, teams:teamsActive() ? teamArray() : null}});
    render();
  }
  function onWorker(e) {
    const d = e.data; if (!think || d.id !== think.id) return;
    if (d.type === 'progress') { think.live = d; if (cur === think.node) { drawMain(); renderCands(); renderStatus(); } renderThink(); return; }
    const node = think.node, playIt = think.playIt; clearTimeout(think.hard); think = null; node.search = d;
    if (playIt && analysisAllowed()) { const m = d.move; const ex = node.children.find(c => c.move === m);
      if (ex) { node.main = node.children.indexOf(ex); if (cur === node) go(ex); }
      else { const s = cloneState(node.state), player = s.toMove, res = play(G, s, m); res.source = 'local'; if (d.guard) res.guard = true;
        const ch = mkNode(node, m, s, res, player, true); node.children.push(ch); node.main = node.children.length - 1; if (cur === node) { moveSound(ch); go(ch); } } }
    render();
    if (autoplay && cur.local && !cur.children.length && !isTerminal(G, cur.state)) setTimeout(() => localSearch(cur, true), 120);
  }
  function heatFor(node) { if (!node || !$('opt-heat').checked) return null; if (think && think.node === node && think.live) return think.live; return node.search; }

  // ---------- navigation ----------
  function go(n) { cur = n; render(); }
  function back() { if (cur.parent) go(cur.parent); }
  function fwd() { if (cur.children.length) go(cur.children[cur.main]); }
  function home() { go(root); }
  function end() { let n = cur; while (n.children.length) n = n.children[n.main]; go(n); }
  function toLive() { let p = live; while (p.parent) { p.parent.main = p.parent.children.indexOf(p); p = p.parent; } go(live); }
  function sib(d) { const p = cur.parent; if (!p) return; const j = p.children.indexOf(cur) + d; if (j < 0 || j >= p.children.length) return; p.main = j; go(p.children[j]); }

  // ---------- board drawing (the Lab's) ----------
  function geomOf(size) { const cell = size / (G.N + 2); return {cell, off:cell * 1.5}; }
  function xy(m, gm) { const x = m % G.W - 1, y = (m / G.W | 0) - 1; return [gm.off + x * gm.cell, gm.off + y * gm.cell]; }
  function hoshi(N) { if (N < 9) return []; const e = N < 13 ? 2 : 3, a = [e, N - 1 - e], out = []; a.forEach(x => a.forEach(y => out.push([x, y]))); if (N % 2) out.push([(N - 1) / 2, (N - 1) / 2]); return out; }
  function drawBoard(ctx, size, node, o) {
    const gm = geomOf(size), cell = gm.cell, off = gm.off, N = G.N, s = node.state;
    ctx.fillStyle = C.wall; ctx.fillRect(0, 0, size, size);
    const e0 = off - cell * .55, e1 = off + (N - 1) * cell + cell * .55; ctx.fillStyle = C.board; ctx.fillRect(e0, e0, e1 - e0, e1 - e0);
    ctx.fillStyle = C.wallInk; ctx.font = '700 ' + Math.round(cell * .4) + 'px Verdana, sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    for (let i = 0; i < N; i++) { const t = off + i * cell; ctx.fillText(COLS[i], t, e0 / 2 + 1); ctx.fillText(COLS[i], t, size - (size - e1) / 2 + 1); ctx.fillText(String(N - i), e0 / 2, t + 1); ctx.fillText(String(N - i), size - (size - e1) / 2, t + 1); }
    ctx.strokeStyle = C.grid; ctx.lineWidth = Math.max(1, cell * .045); ctx.beginPath();
    for (let i = 0; i < N; i++) { const p = Math.round(off + i * cell) + .5; ctx.moveTo(off, p); ctx.lineTo(off + (N - 1) * cell, p); ctx.moveTo(p, off); ctx.lineTo(p, off + (N - 1) * cell); } ctx.stroke();
    ctx.fillStyle = C.grid; hoshi(N).forEach(h => { ctx.beginPath(); ctx.arc(off + h[0] * cell, off + h[1] * cell, cell * .09, 0, 7); ctx.fill(); });
    if (o.territory) { const own = scoreState(G, s, true).owner, q = cell * .26; G.pts.forEach(m => { const w = own[m]; if (w > 0) { const c = xy(m, gm); ctx.fillStyle = PLAYERS[w].fill; ctx.fillRect(c[0] - q / 2, c[1] - q / 2, q, q); ctx.strokeStyle = PLAYERS[w].rim; ctx.lineWidth = Math.max(1, cell * .03); ctx.strokeRect(c[0] - q / 2, c[1] - q / 2, q, q); } }); }
    if (o.heat && o.heat.top && o.heat.total) { const tot = o.heat.total; o.heat.top.forEach((c, ix) => { if (c.move < 0) return; const sh = c.n / tot; if (sh < 0.01) return; const p = xy(c.move, gm);
      ctx.globalAlpha = Math.min(.9, .25 + sh * 1.6); ctx.fillStyle = C.mark; ctx.beginPath(); ctx.arc(p[0], p[1], cell * (.16 + .3 * Math.sqrt(sh)), 0, 7); ctx.fill(); ctx.globalAlpha = 1;
      if (ix < 3 && sh >= 0.03) { ctx.fillStyle = C.boardInk; ctx.font = '700 ' + Math.round(cell * .27) + 'px ui-monospace, monospace'; ctx.fillText(Math.round(sh * 100) + '%', p[0], p[1] + cell * .36); } }); }
    const r = cell * .46;
    G.pts.forEach(m => { const v = s.cells[m]; if (v > 0) { const p = xy(m, gm), P = PLAYERS[v]; ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, 7); ctx.fillStyle = P.fill; ctx.fill(); ctx.lineWidth = Math.max(1.5, cell * .06); ctx.strokeStyle = P.rim; ctx.stroke(); } });
    if (o.last && node.move !== null && node.move >= 0) { const p = xy(node.move, gm), P = PLAYERS[node.player];
      if (s.cells[node.move] === node.player) { ctx.beginPath(); ctx.arc(p[0], p[1], r * 1.04, 0, 7); ctx.lineWidth = Math.max(3, cell * .1); ctx.strokeStyle = node.local ? C.accent : C.mark; ctx.stroke(); ctx.beginPath(); ctx.arc(p[0], p[1], r * .34, 0, 7); ctx.fillStyle = P.ink; ctx.fill(); }
      else { ctx.strokeStyle = P.fill; ctx.lineWidth = Math.max(2, cell * .1); const d = r * .45; ctx.beginPath(); ctx.moveTo(p[0] - d, p[1] - d); ctx.lineTo(p[0] + d, p[1] + d); ctx.moveTo(p[0] + d, p[1] - d); ctx.lineTo(p[0] - d, p[1] + d); ctx.stroke(); } }
    if (o.markers) node.children.forEach((ch, ix) => { if (ch.move < 0) return; const p = xy(ch.move, gm), P = PLAYERS[ch.player], isMain = ix === node.main;
      ctx.globalAlpha = isMain ? .6 : .4; ctx.beginPath(); ctx.arc(p[0], p[1], r * .8, 0, 7); ctx.setLineDash([cell * .1, cell * .08]); ctx.lineWidth = Math.max(2, cell * .07); ctx.strokeStyle = isMain ? C.mark : (ch.player === 2 ? P.rim : P.fill); ctx.stroke(); ctx.setLineDash([]);
      ctx.beginPath(); ctx.arc(p[0], p[1], r * .22, 0, 7); ctx.fillStyle = P.fill; ctx.fill();
      ctx.globalAlpha = isMain ? .85 : .6; ctx.fillStyle = C.boardInk; ctx.font = '700 ' + Math.round(cell * .34) + 'px Verdana, sans-serif'; ctx.fillText(String.fromCharCode(65 + ix), p[0] + r * .62, p[1] - r * .62); ctx.globalAlpha = 1; });
  }
  const cv = $('board'), cctx = cv.getContext('2d'); let cssSize = 0;
  function sizeCanvas() { const w = cv.getBoundingClientRect().width; if (!w) return; cssSize = w; const dpr = window.devicePixelRatio || 1; cv.width = Math.round(w * dpr); cv.height = Math.round(w * dpr); cctx.setTransform(dpr, 0, 0, dpr, 0, 0); drawMain(); }
  new ResizeObserver(sizeCanvas).observe(cv);
  function drawMain() {
    if (!cssSize) return;
    if (!root) { cctx.fillStyle = C.wall; cctx.fillRect(0, 0, cssSize, cssSize); cctx.fillStyle = C.wallInk; cctx.font = '700 20px Verdana, sans-serif'; cctx.textAlign = 'center'; cctx.fillText(gs ? 'The board appears when the game starts.' : '', cssSize / 2, cssSize / 2); return; }
    drawBoard(cctx, cssSize, cur, {territory:$('opt-terr').checked, heat:heatFor(cur), last:true, markers:true});
    const can = hoverPt >= 0 && canPlaceAt(cur, hoverPt);
    cv.style.cursor = hoverPt < 0 ? '' : can ? 'pointer' : 'not-allowed';
    if (can) { // the stone a click would place: the mover's colour, translucent, drawn only here and never sent anywhere
      const gm = geomOf(cssSize), p = xy(hoverPt, gm), P = PLAYERS[cur.state.toMove], r = gm.cell * .46;
      cctx.globalAlpha = .55; cctx.beginPath(); cctx.arc(p[0], p[1], r, 0, 7); cctx.fillStyle = P.fill; cctx.fill();
      cctx.lineWidth = Math.max(1.5, gm.cell * .06); cctx.strokeStyle = P.rim; cctx.stroke(); cctx.globalAlpha = 1;
    }
  }
  // Would a click at m place a stone here? The live position on my own turn, or a variation where analysis is open to me.
  function canPlaceAt(node, m) {
    if (!root || !node || node.state.cells[m] !== 0 || isTerminal(G, node.state)) return false;
    if (node === live && myLiveTurn()) return isLegal(G, node.state, m);
    return analysisAllowed() && isLegal(G, node.state, m);
  }
  let hoverPt = -1;
  function pointAt(e) {
    const rc = cv.getBoundingClientRect(), gm = geomOf(rc.width);
    const x = Math.round((e.clientX - rc.left - gm.off) / gm.cell), y = Math.round((e.clientY - rc.top - gm.off) / gm.cell);
    return x < 0 || y < 0 || x >= G.N || y >= G.N ? -1 : (y + 1) * G.W + x + 1;
  }
  cv.addEventListener('pointermove', e => { if (!root || e.pointerType === 'touch') return; const m = pointAt(e); if (m !== hoverPt) { hoverPt = m; drawMain(); } });
  cv.addEventListener('pointerleave', () => { if (hoverPt !== -1) { hoverPt = -1; drawMain(); } });
  cv.addEventListener('click', e => {
    if (!root) return; const m = pointAt(e); if (m < 0) return;
    const ex = cur.children.find(c => c.move === m); if (ex && !(cur === live && myLiveTurn())) { cur.main = cur.children.indexOf(ex); go(ex); return; }
    tryPlay(cur, m);
  });

  // ---------- panels ----------
  function render() { drawMain(); renderStatus(); renderSeats(); renderControls(); renderCands(); renderChips(); renderTree(); renderThink(); }
  function bowls(node) { const bd = []; for (let i = 0; i <= K; i++) bd.push(new Array(K + 1).fill(0));
    for (let p = node; p && p.parent; p = p.parent) { const inf = p.info; if (!inf) continue; if (inf.victims) for (const v in inf.victims) bd[+v][p.player] += inf.victims[v]; if (inf.suicide) bd[p.player][p.player] += inf.suicide; } return bd; }
  function mctsView(node) {
    const own = (think && think.node === node && think.live) || node.search;
    if (own && own.total) return {proj:own.proj, q:own.rootQ, n:own.total, src:'here', live:!!(think && think.node === node), server:!!own.server};
    const p = node.parent; if (!p) return null; const ps = (think && think.node === p && think.live) || p.search; if (!ps) return null;
    for (const e of ps.top) if (e.move === node.move && e.proj) return {proj:e.proj, q:e.qs, n:e.n, src:'parent', server:!!ps.server};
    return null;
  }
  function renderStatus() {
    const box = $('gv-status'); box.replaceChildren();
    if (!gs) return;
    if (!root) {
      box.append(el('div', {class:'slot big', text:'Waiting to start'}), el('div', {class:'slot muted', text:gs.seats.filter(s => s.controller !== 'open').length + ' of ' + gs.seats.length + ' seats planned or taken. Empty open seats become bots at the start.'}));
      $('gv-scores').replaceChildren(); $('gv-viewsrc').textContent = ''; drawTimeline(); return;
    }
    const s = cur.state, sc = scoreState(G, s, false);
    let L1, L2 = '';
    if (cur === root) { L1 = 'Empty board'; L2 = K + ' players on ' + G.N + '×' + G.N + ', ko rule ' + (s.koOn ? 'on' : 'off') + '.'; }
    else { const i = cur.info || {}; const bits = [];
      if (cur.local) bits.push('your variation (not part of the game)');
      if (i.source === 'deadline') bits.push('deadline expired: board unchanged'); if (i.source === 'person') bits.push('played by ' + seatName(cur.player));
      if (i.source === 'bot') bits.push('played by the server bot'); if (i.source === 'autopilot') bits.push('played by autopilot for ' + seatName(cur.player));
      if (i.guard) bits.push('played on instead of passing to remove dead stones');
      if (i.captured && i.victims) bits.push('captured ' + Object.keys(i.victims).map(v => i.victims[v] + ' ' + PLAYERS[v].name).join(', '));
      if (i.suicide) bits.push('suicide, lost ' + i.suicide); if (i.resigned) bits.push('resigned'); if (i.source === 'resigned') bits.push('automatic pass after resigning');
      L1 = el('span', {}, 'Move ' + cur.depth + ' · ', swatch(cur.player), ' ' + seatName(cur.player) + ' ' + coord(cur.move)); L2 = bits.join(' · '); }
    let L3;
    if (cur === live && gs.status === 'finished') { const ws = gs.winners.map(w => seatName(w)); L3 = el('span', {class:'over', text:'Game over (' + gs.endReason + '). Winner: ' + ws.join(' and ') + '.'}); }
    else if (isTerminal(G, s)) { L3 = el('span', {class:'over', text:'This line is over.'}); }
    else { const w = []; let n = 0; for (let q = 1; q <= K; q++) { if (s.pm & (1 << q)) n++; else if (!(s.out & (1 << q))) w.push(seatName(q)); }
      L3 = el('span', {}, swatch(s.toMove), ' ', el('b', {text:seatName(s.toMove)}), cur === live && myLiveTurn() ? ' — your move' : ' to play', n ? ' · ' + n + ' passed; still to pass: ' + w.join(', ') : ''); }
    let L4 = flashMsg ? el('span', {class:'danger', text:flashMsg}) : (cur !== live ? el('button', {type:'button', class:'linkish', text:'Back to the live game (move ' + live.depth + ')', onclick:toLive}) : '');
    if (mismatch) L4 = el('span', {class:'danger', text:'The replayed board differs from the server board; reload the page.'});
    box.append(el('div', {class:'slot big'}, L1), el('div', {class:'slot muted', text:L2 || ' '}), el('div', {class:'slot'}, L3), el('div', {class:'slot'}, L4 || ' '));
    // score table
    const bd = bowls(cur), vw = mctsView(cur), tA = teamsActive();
    const tbl = $('gv-scores'); tbl.replaceChildren(el('tr', {}, ...['Player', 'Terr.', 'Bowl', 'Score', 'Proj.', 'Outlook'].map(t => el('th', {text:t}))));
    for (let p = 1; p <= K; p++) {
      const seat = gs.seats[p - 1], out = !!(s.out & (1 << p));
      const name = el('td', {class:'name'}, swatch(p), seat.player || PLAYERS[p].name, seat.controller === 'bot' ? el('span', {class:'team', text:'bot'}) : null, seat.controller === 'autopilot' ? el('span', {class:'team', text:'autopilot'}) : null, out ? el('span', {class:'team', text:'resigned'}) : null, tA ? el('span', {class:'team', text:'T' + teamOf(p)}) : null, p === s.toMove && !isTerminal(G, s) ? el('span', {class:'tag', text:'to play'}) : null);
      const parts = []; for (let c = 1; c <= K; c++) { const n = bd[p][c]; if (n) parts.push(el('span', {class:'bk', title:c === p ? 'lost to own suicide' : 'captured by ' + seatName(c)}, c === p ? 'self' : swatch(c), String(n))); }
      tbl.append(el('tr', {class:p === s.toMove && !isTerminal(G, s) ? 'tomove' : ''}, name, el('td', {text:String(sc.terr[p])}), el('td', {}, el('b', {text:String(s.losses[p])}), el('div', {class:'bks'}, ...(parts.length ? parts : [' ']))), el('td', {}, el('b', {text:String(sc.scores[p])})),
        el('td', {text:vw ? vw.proj[p - 1].toFixed(1) : '–'}), el('td', {text:vw ? Math.round(vw.q[p - 1] * 100) + '%' : '–'})));
    }
    if (tA) { const tt = {}, tm = {}, order = []; for (let p = 1; p <= K; p++) { const t = teamOf(p); if (!(t in tt)) { tt[t] = 0; tm[t] = []; order.push(t); } tt[t] += sc.scores[p]; tm[t].push(p); }
      tbl.append(el('tr', {}, el('td', {colspan:'6', class:'small muted left'}, 'Team totals: ', ...order.flatMap(t => [' T' + t + ' ', ...tm[t].map(swatch), ' ', el('b', {text:String(tt[t])}), ' '])))); }
    else tbl.append(el('tr', {}, el('td', {colspan:'6', class:'small muted left', text:'No teams: everyone plays alone.'})));
    $('gv-viewsrc').textContent = !vw ? 'Proj. and Outlook appear for positions a search has weighed: every bot move, or your own analysis.' :
      vw.src === 'here' ? (vw.server ? 'Proj. and Outlook: the server bot\'s search at this position (' : 'Proj. and Outlook: your local search at this position (') + vw.n.toLocaleString() + ' playouts' + (vw.live ? ', running' : '') + ').' :
      'Proj. and Outlook: what the search expected when it weighed this move (' + vw.n.toLocaleString() + ' playouts through it).';
    drawTimeline();
  }
  // seats, teams, merges
  function renderSeats() {
    const box = $('gv-seats'); box.replaceChildren(); if (!gs) return;
    const me = mySeat(), creator = gs.creator === identity, open = gs.status === 'open', n = gs.seats.length;
    for (const st of gs.seats) {
      const p = st.seat, row = el('div', {class:'rrow'}, swatch(p));
      let who = st.player || (st.controller === 'bot' ? 'Bot' : 'Open seat');
      if (st.controller === 'open' && open) who = 'Open seat · a bot if still empty at the start';
      row.append(el('span', {class:'who', text:who + (st.controller === 'autopilot' ? ' (autopilot)' : '')}));
      if (open && creator && st.controller !== 'person') {
        const sel = el('select', {id:'plan-ctl-' + p, 'aria-label':'Seat ' + p + ' controller', onchange:e => void act('set_seat_plan', {seat:p, controller:e.target.value, team:st.team})}, el('option', {value:'open', text:'Person'}), el('option', {value:'bot', text:'Bot'}));
        sel.value = st.controller === 'bot' ? 'bot' : 'open'; row.append(sel);
      } else row.append(el('span', {class:'team', text:st.controller === 'person' || st.controller === 'autopilot' ? 'person' : st.controller}));
      if (open && creator) { const ts = el('select', {id:'plan-team-' + p, 'aria-label':'Seat ' + p + ' team', onchange:e => void act('set_seat_plan', {seat:p, controller:st.controller === 'bot' ? 'bot' : 'open', team:+e.target.value})});
        for (let t = 1; t <= n; t++) ts.append(el('option', {value:String(t), text:'Team ' + t})); ts.value = String(st.team); row.append(ts); }
      else row.append(el('span', {class:'team', text:'T' + st.team}));
      if (open && st.controller === 'open' && !me) row.append(el('button', {type:'button', text:'Sit here', onclick:() => void act('take_seat', {seat:p}, 'You took seat ' + p + '.')}));
      else if (open && me === p) row.append(el('button', {type:'button', text:'Leave', onclick:() => void act('leave_seat', {}, 'You left your seat.')}));
      box.append(row);
    }
    // merge proposals
    const mb = $('gv-merges'); mb.replaceChildren();
    if (gs.status === 'playing' && me) {
      const myTeam = gs.seats[me - 1].team, others = [...new Set(gs.seats.map(s => s.team))].filter(t => t !== myTeam);
      if (others.length) { const sel = el('select', {id:'merge-team', 'aria-label':'Team to merge with'}, ...others.map(t => el('option', {value:String(t), text:'Team ' + t + ' (' + gs.seats.filter(s => s.team === t).map(s => s.player).join(', ') + ')'})));
        mb.append(el('div', {class:'row'}, el('span', {text:'Merge my team with'}), sel, el('button', {type:'button', text:'Propose', onclick:() => void act('propose_merge', {otherTeam:+sel.value}, 'Proposal sent. Everyone on both teams must accept.')}))); }
    }
    for (const pr of (gs.proposals || [])) {
      const mine = pr.waitingFor.includes(identity);
      mb.append(el('div', {class:mine ? 'proposal mine' : 'proposal'}, el('div', {text:'Team ' + pr.teamA + ' + Team ' + pr.teamB + ', proposed by ' + pr.proposer}), el('div', {class:'small muted', text:'Accepted: ' + (pr.acceptedBy.join(', ') || 'nobody') + ' · waiting for: ' + (pr.waitingFor.join(', ') || 'nobody')}),
        mine ? el('div', {class:'row'}, el('button', {type:'button', text:'Accept merge', onclick:() => void act('respond_merge', {proposalId:pr.proposalId, accept:true})}), el('button', {type:'button', text:'Decline', onclick:() => void act('respond_merge', {proposalId:pr.proposalId, accept:false})})) : null));
    }
    if (!mb.children.length) mb.append(el('p', {class:'small muted', text:gs.status === 'playing' ? (me ? 'No pending merges.' : 'Seated people can propose merging teams; every person on both teams must accept.') : 'Teams can merge once the game is playing. Merges are permanent.'}));
  }
  function renderControls() {
    if (!gs) return;
    const playing = gs.status === 'playing', me = mySeat(), ctl = myControl();
    $('gv-start').hidden = !(gs.status === 'open' && gs.creator === identity);
    $('gv-pass').disabled = $('gv-resign').disabled = !myLiveTurn() || cur !== live;
    $('gv-autopilot').hidden = !(playing && me); $('gv-autopilot').textContent = ctl === 'autopilot' ? 'Take my seat back' : 'Let a bot play for me';
    const can = !!root && analysisAllowed();
    $('gv-move').disabled = !can || !!think || isTerminal(G, cur.state); $('gv-auto').disabled = !can; $('gv-analyze').disabled = !can || !!think || isTerminal(G, cur.state);
    $('gv-auto').textContent = autoplay ? 'Stop autoplay' : 'Autoplay variation'; $('gv-auto').classList.toggle('on', autoplay);
    $('gv-analysis-note').textContent = !root ? '' : can ? 'Analysis runs in your browser only and never changes the game.' : (me && playing ? 'You are seated: step through the game freely; variations and local search unlock when the game ends.' : '');
    if (!root) return;
    $('nav-back').disabled = $('nav-home').disabled = !cur.parent; $('nav-fwd').disabled = $('nav-end').disabled = !cur.children.length;
    const p = cur.parent, i = p ? p.children.indexOf(cur) : 0; $('nav-up').disabled = !p || i <= 0; $('nav-down').disabled = !p || i >= p.children.length - 1; $('nav-live').disabled = cur === live;
    $('gv-gif').disabled = false;
  }
  function renderThink() {
    const t = $('gv-think'); if (!gs) { t.textContent = ''; return; }
    if (think) { const l = think.live; t.textContent = 'Your local search' + (l ? ' · ' + l.iters.toLocaleString() + ' playouts' : '') + ' · ' + (think.dead / 1000) + ' s'; return; }
    if (gs.status !== 'playing') { t.textContent = gs.status === 'finished' ? 'Game over.' : 'Waiting for the creator to start.'; return; }
    const seat = gs.seats[gs.toMove - 1]; t.textContent = seat.controller === 'person' ? (gs.toMove === mySeat() ? 'Your move: click a point, or Pass.' : seat.player + ' to move.') : (seat.controller === 'autopilot' ? 'Autopilot is thinking for ' + seat.player + '.' : seat.player + ' (server bot) is thinking.');
  }
  function renderCands() {
    let d = heatFor(cur) || (cur && cur.search), note = '';
    if ((!d || !d.top || !d.top.length) && cur && cur.parent && cur.parent.search) { d = cur.parent.search; note = 'The search that chose the move just played, at the position before it:'; }
    const box = $('gv-cands'); box.replaceChildren(el('div', {class:'cand head'}, el('span', {text:'Move'}), el('span', {text:'Visits'}), el('span', {text:'Share'}), el('span', {text:'Reward'})));
    if (!d || !d.top || !d.top.length) { box.append(el('div', {class:'muted small pad', text:'Candidates appear here for every bot move, and for your own analysis when it is allowed.'})); return; }
    if (note) box.append(el('div', {class:'muted small', text:note}));
    const at = note ? cur.parent : cur;
    d.top.slice(0, 8).forEach(c => { const sh = c.n / d.total; const bar = el('span', {class:'bar'}, el('i', {style:{width:(sh * 100) + '%'}}));
      box.append(el('button', {type:'button', class:'cand' + (note && c.move === cur.move ? ' chosen' : ''), onclick:() => { if (at !== cur) go(at); tryPlay(at, c.move); }}, el('span', {text:coord(c.move)}), el('span', {text:Math.round(sh * 100) + '%'}), bar, el('span', {text:Math.round(c.q * 100) + '%'}))); });
  }
  function renderChips() {
    const box = $('gv-chips'); box.replaceChildren(el('span', {class:'lab', text:'Next'})); if (!root) return;
    if (!cur.children.length) { box.append(el('span', {class:'muted small', text:cur === live ? 'This is the live position.' : 'No continuation yet.'})); return; }
    cur.children.forEach((c, i) => box.append(el('button', {type:'button', class:'chip' + (i === cur.main ? ' main' : '') + (c.local ? ' local' : ''), onclick:() => { cur.main = i; go(c); }}, String.fromCharCode(65 + i) + ' ', swatch(c.player), coord(c.move))));
  }
  function renderTree() {
    const box = $('gv-tree'); box.replaceChildren(); if (!root) return;
    const dx = 18, dy = 24, pad = 14; let maxRow = 0, maxD = 0; const list = [];
    (function lay(n, r) { n._r = r; if (r > maxRow) maxRow = r; if (n.depth > maxD) maxD = n.depth; list.push(n); n.children.forEach((c, i) => lay(c, i === 0 ? r : maxRow + 1)); })(root, 0);
    const onPath = new Set(); for (let p = cur; p; p = p.parent) onPath.add(p.id);
    const W = pad * 2 + maxD * dx, H = pad * 2 + maxRow * dy, NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('width', W); svg.setAttribute('height', H); svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    const X = n => pad + n.depth * dx, Y = n => pad + n._r * dy;
    const add = (tag, attrs, title) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); if (title) { const t = document.createElementNS(NS, 'title'); t.textContent = title; e.append(t); } svg.append(e); return e; };
    list.forEach(n => { if (n.parent) { const on = onPath.has(n.id); add('path', {d:'M' + X(n.parent) + ' ' + Y(n.parent) + (n._r !== n.parent._r ? ' V' + Y(n) + ' H' + X(n) : ' H' + X(n)), fill:'none', stroke:on ? C.ink : C.rule, 'stroke-width':on ? 2.5 : 1.5, 'stroke-dasharray':n.local ? '4 3' : 'none'}); } });
    list.forEach(n => { const x = X(n), y = Y(n);
      if (n === cur) add('circle', {cx:x, cy:y, r:10, fill:'none', stroke:C.accent, 'stroke-width':3});
      if (n === live) add('circle', {cx:x, cy:y, r:13, fill:'none', stroke:C.mark, 'stroke-width':2});
      if (!n.parent) add('rect', {'data-id':n.id, x:x - 6, y:y - 6, width:12, height:12, fill:C.muted});
      else { const P = PLAYERS[n.player], t = seatName(n.player) + ' ' + coord(n.move) + ' (move ' + n.depth + (n.local ? ', variation' : '') + ')';
        if (n.move === RESIGN) add('rect', {'data-id':n.id, x:x - 5.5, y:y - 5.5, width:11, height:11, fill:C.bg, stroke:P.fill, 'stroke-width':2.5}, t);
        else if (n.move < 0) add('circle', {'data-id':n.id, cx:x, cy:y, r:5.5, fill:C.bg, stroke:P.fill, 'stroke-width':2.5}, t);
        else add('circle', {'data-id':n.id, cx:x, cy:y, r:6.5, fill:n.local ? C.bg : P.fill, stroke:n.local ? P.fill : P.rim, 'stroke-width':n.local ? 2.5 : 1.5}, t); } });
    svg.addEventListener('click', e => { const id = e.target.getAttribute && e.target.getAttribute('data-id'); if (!id) return; const n = byId.get(+id); for (let q = n; q.parent; q = q.parent) q.parent.main = q.parent.children.indexOf(q); go(n); });
    box.append(svg);
    const cx = X(cur), cy = Y(cur);
    if (cx < box.scrollLeft + 20 || cx > box.scrollLeft + box.clientWidth - 20) box.scrollLeft = cx - box.clientWidth / 2;
    if (cy < box.scrollTop + 20 || cy > box.scrollTop + box.clientHeight - 20) box.scrollTop = cy - box.clientHeight / 2;
  }
  // projected-score timeline (DesiredOutput game.score_timeline)
  const tl = $('gv-timeline'); let tlNodes = [];
  function drawTimeline() {
    const w = tl.getBoundingClientRect().width, h = 150; if (!w) return; const dpr = window.devicePixelRatio || 1;
    tl.width = Math.round(w * dpr); tl.height = Math.round(h * dpr); const x = tl.getContext('2d'); x.setTransform(dpr, 0, 0, dpr, 0, 0); x.fillStyle = C.bg; x.fillRect(0, 0, w, h);
    if (!root) { tlNodes = []; return; }
    const line = []; for (let p = cur; p; p = p.parent) line.unshift(p); const ci = line.length - 1; for (let q = cur; q.children.length;) { q = q.children[q.main]; line.push(q); } tlNodes = line;
    const vals = line.map(mctsView); let lo = 0, hi = 0; vals.forEach(v => { if (v) v.proj.forEach(s => { lo = Math.min(lo, s); hi = Math.max(hi, s); }); });
    const L = 34, R = 8, T = 10, B = 22, span = Math.max(1, line.length - 1); if (hi - lo < 4) { hi += 2; lo -= 2; }
    const X = i => L + (w - L - R) * i / span, Y = s => T + (h - T - B) * (hi - s) / (hi - lo);
    x.font = '13px ui-monospace, monospace'; x.fillStyle = C.muted; x.textBaseline = 'middle'; x.textAlign = 'right';
    x.fillText(String(Math.round(hi)), L - 6, Y(hi)); x.fillText(String(Math.round(lo)), L - 6, Y(lo)); x.strokeStyle = C.rule; x.lineWidth = 1; x.beginPath(); x.moveTo(L, Y(0)); x.lineTo(w - R, Y(0)); x.stroke(); x.fillText('0', L - 6, Y(0));
    x.textAlign = 'left'; x.textBaseline = 'alphabetic'; x.fillText('move 0', L, h - 5); x.textAlign = 'right'; x.fillText('move ' + (line.length - 1), w - R, h - 5);
    for (let pl = 1; pl <= K; pl++) { x.strokeStyle = pl === 1 ? PLAYERS[1].rim : PLAYERS[pl].fill; x.lineWidth = 2.5; x.setLineDash(pl === 1 ? [5, 4] : []);
      for (let seg = 0; seg < 2; seg++) { x.globalAlpha = seg ? .35 : 1; x.beginPath(); let on = false;
        for (let i = seg ? ci : 0; i <= (seg ? line.length - 1 : ci); i++) { const v = vals[i]; if (!v) { on = false; continue; } const px = X(i), py = Y(v.proj[pl - 1]); if (on) x.lineTo(px, py); else { x.moveTo(px, py); on = true; } } x.stroke(); }
      x.globalAlpha = 1; x.setLineDash([]); }
    x.strokeStyle = C.accent; x.lineWidth = 2; x.beginPath(); x.moveTo(X(ci), T - 4); x.lineTo(X(ci), h - B + 4); x.stroke();
  }
  tl.addEventListener('click', e => { if (!tlNodes.length) return; const r = tl.getBoundingClientRect(), L = 34, R = 8, span = Math.max(1, tlNodes.length - 1);
    let i = Math.round((e.clientX - r.left - L) / ((r.width - L - R) / span)); i = Math.max(0, Math.min(tlNodes.length - 1, i));
    for (let n = tlNodes[i]; n.parent; n = n.parent) n.parent.main = n.parent.children.indexOf(n); go(tlNodes[i]); });
  new ResizeObserver(() => drawTimeline()).observe(tl);

  // ---------- sounds (the Lab's) ----------
  let audio = null;
  function unlockAudio() { try { if (!audio) { const A = window.AudioContext || window.webkitAudioContext; if (A) audio = new A(); } if (audio && audio.state === 'suspended') audio.resume(); } catch (e) {} }
  document.addEventListener('pointerdown', unlockAudio); document.addEventListener('keydown', unlockAudio);
  function beep(freq, ms, at) { if (!$('opt-sound').checked || !audio) return; try { const t = audio.currentTime + (at || 0), o = audio.createOscillator(), g = audio.createGain(); o.type = 'sine'; o.frequency.value = freq; g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.25, t + 0.01); g.gain.exponentialRampToValueAtTime(0.0001, t + ms / 1000); o.connect(g); g.connect(audio.destination); o.start(t); o.stop(t + ms / 1000 + 0.02); } catch (e) {} }
  function clack(freq, vol) { if (!$('opt-sound').checked || !audio) return; try { const t = audio.currentTime, len = Math.floor(audio.sampleRate * 0.05), buf = audio.createBuffer(1, len, audio.sampleRate), d = buf.getChannelData(0); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 4);
    const src = audio.createBufferSource(), f = audio.createBiquadFilter(), g = audio.createGain(); src.buffer = buf; f.type = 'bandpass'; f.frequency.value = freq; f.Q.value = 3; g.gain.value = vol; src.connect(f); f.connect(g); g.connect(audio.destination); src.start(t); } catch (e) {} }
  function moveSound(ch) { if (!ch || !ch.info) return; if (ch.move >= 0) { clack(2400, .9); if (ch.info.captured) setTimeout(() => { clack(900, 1); clack(600, .8); }, 90); } }

  // ---------- clock ----------
  let warned = -1, lastTick = 0;
  function tickClock() {
    const ck = $('gv-clock'), bar = $('gv-deadbar');
    if (!gs || gs.status !== 'playing') { ck.textContent = '–:––'; ck.classList.add('idle'); ck.classList.remove('warn'); bar.style.width = '0'; bar.parentNode.classList.remove('warn'); return; }
    const seat = gs.seats[gs.toMove - 1], botTurn = seat.controller !== 'person', limit = botTurn ? gs.botMs : gs.turnDeadlineMs, left = gs.remainingMs - (performance.now() - gs.stateAt);
    const mine = gs.toMove === mySeat() && !botTurn, warn = !botTurn && left <= 10000;
    ck.classList.remove('idle'); ck.textContent = fmtClock(left); ck.classList.toggle('warn', warn); bar.parentNode.classList.toggle('warn', warn); bar.style.width = Math.min(100, Math.max(0, (1 - left / limit) * 100)) + '%';
    if (mine && warn && warned !== gs.moveNo) { warned = gs.moveNo; beep(880, 140); beep(880, 140, .22); }
    const sec = Math.ceil(left / 1000); if (mine && sec <= 5 && sec > 0 && sec !== lastTick) { lastTick = sec; beep(1320, 60); }
  }
  function fmtClock(ms) { const s = Math.max(0, Math.ceil(ms / 1000)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }
  setInterval(tickClock, 200);

  // ---------- GIF export (the Lab's encoder) ----------
  function hex(c) { c = c.replace('#', ''); return [parseInt(c.slice(0, 2), 16), parseInt(c.slice(2, 4), 16), parseInt(c.slice(4, 6), 16)]; }
  function buildPalette() { const base = [C.bg, C.ink, C.muted, C.accent, C.board, C.grid, C.wall, C.wallInk, C.mark, C.boardInk]; for (let i = 1; i <= K; i++) base.push(PLAYERS[i].fill, PLAYERS[i].rim, PLAYERS[i].ink);
    const b = base.map(hex), pal = [], seen = new Set(); const addc = c => { const k = c.join(','); if (!seen.has(k) && pal.length < 256) { seen.add(k); pal.push(c); } }; b.forEach(addc);
    const blends = (a, list, steps) => list.forEach(c => { for (let s = 1; s < steps; s++) { const t = s / steps; addc([0, 1, 2].map(j => Math.round(a[j] * (1 - t) + c[j] * t))); } });
    blends(hex(C.board), b, 7); blends(hex(C.bg), b, 6); blends(hex(C.wall), [hex(C.wallInk), hex(C.board)], 6); for (let i = 1; i <= K; i++) blends(hex(PLAYERS[i].fill), [hex(PLAYERS[i].rim), hex(PLAYERS[i].ink)], 5); return pal; }
  function lzw(idx, minCode) { const out = []; let cur = 0, bits = 0; const clear = 1 << minCode, eoi = clear + 1; let size = minCode + 1, next = eoi + 1; const dict = new Map();
    const emit = c => { cur |= c << bits; bits += size; while (bits >= 8) { out.push(cur & 255); cur >>>= 8; bits -= 8; } }; emit(clear); let pre = idx[0];
    for (let i = 1; i < idx.length; i++) { const k = idx[i], key = (pre << 8) | k, v = dict.get(key); if (v === undefined) { emit(pre); if (next === 4096) { emit(clear); dict.clear(); next = eoi + 1; size = minCode + 1; } else { if (next >= (1 << size)) size++; dict.set(key, next++); } pre = k; } else pre = v; }
    emit(pre); emit(eoi); if (bits > 0) out.push(cur & 255); return out; }
  function encodeGif(w, h, pal, frames, delays) { const b = []; const s16 = v => b.push(v & 255, (v >> 8) & 255); 'GIF89a'.split('').forEach(c => b.push(c.charCodeAt(0))); s16(w); s16(h); b.push(0xF7, 0, 0);
    for (let i = 0; i < 256; i++) { const c = pal[i] || [0, 0, 0]; b.push(c[0], c[1], c[2]); } b.push(0x21, 0xFF, 0x0B); 'NETSCAPE2.0'.split('').forEach(c => b.push(c.charCodeAt(0))); b.push(3, 1, 0, 0, 0);
    const chunks = [new Uint8Array(b)]; frames.forEach((f, fi) => { const hd = [0x21, 0xF9, 4, 0x04, delays[fi] & 255, (delays[fi] >> 8) & 255, 0, 0, 0x2C, 0, 0, 0, 0, w & 255, w >> 8, h & 255, h >> 8, 0, 8]; const data = lzw(f, 8), body = [];
      for (let p = 0; p < data.length; p += 255) { const n = Math.min(255, data.length - p); body.push(n); for (let q = 0; q < n; q++) body.push(data[p + q]); } body.push(0); chunks.push(new Uint8Array(hd), new Uint8Array(body)); });
    chunks.push(new Uint8Array([0x3B])); return new Blob(chunks, {type:'image/gif'}); }
  function drawFrame(ctx, S, hdr, node) { const f = Math.round(S * .036); ctx.fillStyle = C.bg; ctx.fillRect(0, 0, S, hdr); ctx.save(); ctx.translate(0, hdr); drawBoard(ctx, S, node, {territory:$('opt-terr').checked, heat:null, last:true, markers:false}); ctx.restore();
    const pad = Math.round(f * .7); ctx.textBaseline = 'middle'; ctx.textAlign = 'left'; ctx.font = '700 ' + Math.round(f * 1.1) + 'px Verdana, sans-serif'; ctx.fillStyle = C.ink;
    ctx.fillText(node === root ? 'Start' : 'Move ' + node.depth + '  ' + seatName(node.player) + ' ' + coord(node.move), pad, Math.round(f * 1.2));
    const sc = scoreState(G, node.state, false).scores, per = Math.min(K, 4), cw = (S - 2 * pad) / per;
    for (let p = 1; p <= K; p++) { const r = Math.floor((p - 1) / per), col = (p - 1) % per, x = pad + col * cw, y = Math.round(f * 2.1 + r * f * 1.9 + f * .95);
      ctx.beginPath(); ctx.arc(x + f * .5, y, f * .45, 0, 7); ctx.fillStyle = PLAYERS[p].fill; ctx.fill(); ctx.lineWidth = 1.5; ctx.strokeStyle = PLAYERS[p].rim; ctx.stroke();
      ctx.font = '700 ' + Math.round(f * 1.05) + 'px ui-monospace, monospace'; ctx.fillStyle = C.ink; ctx.fillText(sc[p] + '  lost ' + node.state.losses[p], x + f * 1.25, y); } }
  async function makeGif() {
    if (!root) return; const btn = $('gv-gif'), out = $('gv-gifout'); btn.disabled = true; out.replaceChildren(el('div', {class:'small muted', text:'Rendering…'}));
    try { const path = []; for (let p = cur; p; p = p.parent) path.unshift(p);
      const S = +$('gif-size').value, f = Math.round(S * .036), rows = Math.ceil(K / Math.min(K, 4)), hdr = Math.round(f * 2.1 + rows * f * 1.9 + f * .4), H = S + hdr, oc = document.createElement('canvas'); oc.width = S; oc.height = H;
      const ctx = oc.getContext('2d', {willReadFrequently:true}), pal = buildPalette(), cache = new Int16Array(32768).fill(-1), frames = [], delays = [], dly = Math.round(+$('gif-delay').value / 10);
      for (let i = 0; i < path.length; i++) { drawFrame(ctx, S, hdr, path[i]); const px = ctx.getImageData(0, 0, S, H).data, ix = new Uint8Array(S * H);
        for (let j = 0, o = 0; j < ix.length; j++, o += 4) { const r = px[o], g = px[o + 1], b = px[o + 2], key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3); let v = cache[key];
          if (v < 0) { let best = 0, bd = 1e9; for (let q = 0; q < pal.length; q++) { const c = pal[q], dr = c[0] - r, dg = c[1] - g, db = c[2] - b, dd = dr * dr * 2 + dg * dg * 4 + db * db * 3; if (dd < bd) { bd = dd; best = q; } } cache[key] = v = best; } ix[j] = v; }
        frames.push(ix); delays.push(i === path.length - 1 ? 250 : (i === 0 ? Math.max(dly, 60) : dly)); await new Promise(r => setTimeout(r, 0)); }
      const blob = encodeGif(S, H, pal, frames, delays), url = URL.createObjectURL(blob), name = 'goserver-' + G.N + 'x' + G.N + '-' + K + 'p-move' + cur.depth + '.gif';
      out.replaceChildren(el('img', {alt:'Animated replay to move ' + cur.depth, src:url}), el('a', {href:url, download:name, class:'button', text:'Save ' + name}), el('span', {class:'small muted', text:' ' + frames.length + ' frames · ' + Math.round(blob.size / 1024) + ' KB'}));
    } catch (err) { out.replaceChildren(el('div', {class:'danger', text:'GIF failed: ' + (err && err.message || err)})); }
    btn.disabled = false;
  }

  // ---------- wiring ----------
  $('nav-home').onclick = home; $('nav-back').onclick = back; $('nav-fwd').onclick = fwd; $('nav-end').onclick = end; $('nav-up').onclick = () => sib(-1); $('nav-down').onclick = () => sib(1); $('nav-live').onclick = toLive;
  $('gv-start').onclick = () => void act('start_game', {}, 'Game started. Bots took the empty seats.');
  $('gv-pass').onclick = () => { if (myLiveTurn() && cur === live) void serverMove('pass', -1); };
  let resignArm = 0;
  $('gv-resign').onclick = () => { const b = $('gv-resign'); if (!resignArm) { b.textContent = 'Confirm resign'; resignArm = setTimeout(() => { resignArm = 0; b.textContent = 'Resign'; }, 3000); return; } clearTimeout(resignArm); resignArm = 0; b.textContent = 'Resign'; if (myLiveTurn()) void serverMove('resign', RESIGN); };
  $('gv-autopilot').onclick = () => void act('set_autopilot', {on:myControl() !== 'autopilot'});
  $('gv-move').onclick = () => localSearch(cur, true); $('gv-analyze').onclick = () => localSearch(cur, false);
  $('gv-auto').onclick = () => { autoplay = !autoplay; renderControls(); if (autoplay && root && analysisAllowed() && !think && !isTerminal(G, cur.state)) localSearch(cur, true); };
  $('opt-terr').onchange = drawMain; $('opt-heat').onchange = () => { drawMain(); renderCands(); };
  $('gv-gif').onclick = () => void makeGif();
  document.addEventListener('keydown', e => {
    if (!gameId || !root) return; const t = e.target.tagName; if (t === 'INPUT' || t === 'SELECT' || t === 'TEXTAREA' || e.target.getAttribute('role') === 'tab') return; const k = e.key;
    if (k === 'ArrowLeft') { back(); e.preventDefault(); } else if (k === 'ArrowRight') { fwd(); e.preventDefault(); } else if (k === 'ArrowUp') { sib(-1); e.preventDefault(); } else if (k === 'ArrowDown') { sib(1); e.preventDefault(); }
    else if (k === 'Home') { home(); e.preventDefault(); } else if (k === 'End') { end(); e.preventDefault(); } else if (k === 'l' || k === 'L') toLive();
    else if ((k === 'c' || k === 'C') && analysisAllowed()) localSearch(cur, true); else if ((k === 'p' || k === 'P') && myLiveTurn() && cur === live) void serverMove('pass', -1);
  });

  // ---------- side-panel tabs (the play bar above them stays visible) ----------
  const TABS = ['scores', 'search', 'seats', 'chat', 'gif'];
  let tab = 'scores', chatSeen = 0;
  try { const t = localStorage.getItem('goserver.tab'); if (TABS.includes(t)) tab = t; } catch (e) {}
  function showTab(name) {
    tab = name;
    TABS.forEach(t => { const b = $('tab-' + t), panel = $('panel-' + t), on = t === name; b.setAttribute('aria-selected', on ? 'true' : 'false'); b.tabIndex = on ? 0 : -1; panel.hidden = !on; });
    try { localStorage.setItem('goserver.tab', name); } catch (e) {}
    if (name === 'scores') drawTimeline();
    if (name === 'chat') chatSeen = $('game-chat').querySelectorAll('.chat-item').length;
    updateBadges();
  }
  function updateBadges() {
    const n = $('game-chat').querySelectorAll('.chat-item').length; if (n < chatSeen || tab === 'chat') chatSeen = n;
    const unread = n - chatSeen; $('badge-chat').textContent = unread ? String(unread) : ''; $('badge-chat').hidden = !unread;
    const pending = tab !== 'seats' && !!$('gv-merges').querySelector('.proposal.mine'); /* a merge waits for my answer */ $('badge-seats').hidden = !pending;
  }
  TABS.forEach(t => { $('tab-' + t).addEventListener('click', () => showTab(t)); });
  $('gv-tabs').addEventListener('keydown', e => { // arrow keys move between tabs while a tab has focus
    const i = TABS.indexOf(tab); let j = -1;
    if (e.key === 'ArrowRight') j = (i + 1) % TABS.length; else if (e.key === 'ArrowLeft') j = (i + TABS.length - 1) % TABS.length;
    if (j < 0) return; e.preventDefault(); e.stopPropagation(); showTab(TABS[j]); $('tab-' + TABS[j]).focus();
  });
  new MutationObserver(updateBadges).observe($('game-chat'), {childList:true});
  new MutationObserver(updateBadges).observe($('gv-merges'), {childList:true, subtree:true});
  showTab(tab);

  // Read-only probes for the scripted book tour (source/book_tour.py); they change nothing.
  window.GameViewDebug = {point:(x, y) => (live ? live.state.cells[ptOf(x, y)] : -1), tab:() => tab, showTab:(t) => showTab(t), size:() => (G ? G.N : 9), liveMove:() => records.length, lastSource:() => (records.length ? records[records.length - 1].source : ''), status:() => (gs ? gs.status : '')};
  return {
    open(id) { if (gameId === id) return; reset(); gameId = id; epoch++; render(); void refresh().then(schedule); },
    close() { reset(); gameId = ''; epoch++; clearTimeout(pollTimer); render(); },
  };
})();
