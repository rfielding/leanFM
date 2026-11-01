// Requirement refs: property:Lab-style viewer. The Lab's board drawing, unchanged in look.
export const PLAYERS: any[] = [null,
  {name: 'Black', fill: '#0a0a0b', rim: '#d8d2c6', ink: '#ffffff'}, {name: 'White', fill: '#f3f1ec', rim: '#6e675c', ink: '#111111'},
  {name: 'Red', fill: '#ef4d55', rim: '#140c0c', ink: '#ffffff'}, {name: 'Blue', fill: '#4d8dff', rim: '#0b1020', ink: '#ffffff'},
  {name: 'Green', fill: '#3cc46e', rim: '#08160d', ink: '#0b1a10'}, {name: 'Violet', fill: '#b483ff', rim: '#140c20', ink: '#ffffff'},
  {name: 'Orange', fill: '#ff8f3a', rim: '#1c0f05', ink: '#1c0f05'}, {name: 'Cyan', fill: '#3ccfdc', rim: '#061618', ink: '#061618'}];
export const C = {bg: '#0e1115', panel: '#161a20', ink: '#f1f3f6', muted: '#b9c2ce', accent: '#ffc94d', board: '#dcb35c', boardInk: '#2a1d08', mark: '#0a4fc4', grid: '#3d2b12', wall: '#434951', wallInk: '#e3e7ed', rule: '#323a46'};
export const COLS = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';

export function geomOf(G: any, size: number) { const cell = size / (G.N + 2); return {cell, off: cell * 1.5}; }
export function xy(G: any, m: number, gm: {cell: number; off: number}) { const x = m % G.W - 1, y = (m / G.W | 0) - 1; return [gm.off + x * gm.cell, gm.off + y * gm.cell]; }
function hoshi(N: number) { if (N < 9) return []; const e = N < 13 ? 2 : 3, a = [e, N - 1 - e], out: number[][] = []; a.forEach(x => a.forEach(y => out.push([x, y]))); if (N % 2) out.push([(N - 1) / 2, (N - 1) / 2]); return out; }

export interface DrawOpts { territory: boolean; heat: any; last: boolean; markers: boolean; }

export function drawBoard(G: any, ctx: CanvasRenderingContext2D, size: number, node: any, o: DrawOpts) {
  const gm = geomOf(G, size), cell = gm.cell, off = gm.off, N = G.N, s = node.state;
  ctx.fillStyle = C.wall; ctx.fillRect(0, 0, size, size);
  const e0 = off - cell * .55, e1 = off + (N - 1) * cell + cell * .55; ctx.fillStyle = C.board; ctx.fillRect(e0, e0, e1 - e0, e1 - e0);
  ctx.fillStyle = C.wallInk; ctx.font = '700 ' + Math.round(cell * .4) + 'px Verdana, sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  for (let i = 0; i < N; i++) { const t = off + i * cell; ctx.fillText(COLS[i], t, e0 / 2 + 1); ctx.fillText(COLS[i], t, size - (size - e1) / 2 + 1); ctx.fillText(String(N - i), e0 / 2, t + 1); ctx.fillText(String(N - i), size - (size - e1) / 2, t + 1); }
  ctx.strokeStyle = C.grid; ctx.lineWidth = Math.max(1, cell * .045); ctx.beginPath();
  for (let i = 0; i < N; i++) { const p = Math.round(off + i * cell) + .5; ctx.moveTo(off, p); ctx.lineTo(off + (N - 1) * cell, p); ctx.moveTo(p, off); ctx.lineTo(p, off + (N - 1) * cell); } ctx.stroke();
  ctx.fillStyle = C.grid; hoshi(N).forEach(h => { ctx.beginPath(); ctx.arc(off + h[0] * cell, off + h[1] * cell, cell * .09, 0, 7); ctx.fill(); });
  if (o.territory) { const own = scoreState(G, s, true).owner, q = cell * .26; G.pts.forEach((m: number) => { const w = own[m]; if (w > 0) { const c = xy(G, m, gm); ctx.fillStyle = PLAYERS[w].fill; ctx.fillRect(c[0] - q / 2, c[1] - q / 2, q, q); ctx.strokeStyle = PLAYERS[w].rim; ctx.lineWidth = Math.max(1, cell * .03); ctx.strokeRect(c[0] - q / 2, c[1] - q / 2, q, q); } }); }
  if (o.heat && o.heat.top && o.heat.total) {
    const tot = o.heat.total;
    o.heat.top.forEach((c: any, ix: number) => { if (c.move < 0) return; const sh = c.n / tot; if (sh < 0.01) return; const p = xy(G, c.move, gm);
      ctx.globalAlpha = Math.min(.9, .25 + sh * 1.6); ctx.fillStyle = C.mark; ctx.beginPath(); ctx.arc(p[0], p[1], cell * (.16 + .3 * Math.sqrt(sh)), 0, 7); ctx.fill(); ctx.globalAlpha = 1;
      if (ix < 3 && sh >= 0.03) { ctx.fillStyle = C.boardInk; ctx.font = '700 ' + Math.round(cell * .27) + 'px ui-monospace, monospace'; ctx.fillText(Math.round(sh * 100) + '%', p[0], p[1] + cell * .36); } });
  }
  const r = cell * .46;
  G.pts.forEach((m: number) => { const v = s.cells[m]; if (v > 0) { const p = xy(G, m, gm), P = PLAYERS[v]; ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, 7); ctx.fillStyle = P.fill; ctx.fill(); ctx.lineWidth = Math.max(1.5, cell * .06); ctx.strokeStyle = P.rim; ctx.stroke(); } });
  if (o.last && node.move !== null && node.move >= 0) {
    const p = xy(G, node.move, gm), P = PLAYERS[node.player];
    if (s.cells[node.move] === node.player) { ctx.beginPath(); ctx.arc(p[0], p[1], r * 1.04, 0, 7); ctx.lineWidth = Math.max(3, cell * .1); ctx.strokeStyle = node.local ? C.accent : C.mark; ctx.stroke(); ctx.beginPath(); ctx.arc(p[0], p[1], r * .34, 0, 7); ctx.fillStyle = P.ink; ctx.fill(); }
    else { ctx.strokeStyle = P.fill; ctx.lineWidth = Math.max(2, cell * .1); const d = r * .45; ctx.beginPath(); ctx.moveTo(p[0] - d, p[1] - d); ctx.lineTo(p[0] + d, p[1] + d); ctx.moveTo(p[0] + d, p[1] - d); ctx.lineTo(p[0] - d, p[1] + d); ctx.stroke(); }
  }
  if (o.markers) node.children.forEach((ch: any, ix: number) => { if (ch.move < 0) return; const p = xy(G, ch.move, gm), P = PLAYERS[ch.player], isMain = ix === node.main;
    ctx.globalAlpha = isMain ? .6 : .4; ctx.beginPath(); ctx.arc(p[0], p[1], r * .8, 0, 7); ctx.setLineDash([cell * .1, cell * .08]); ctx.lineWidth = Math.max(2, cell * .07); ctx.strokeStyle = isMain ? C.mark : (ch.player === 2 ? P.rim : P.fill); ctx.stroke(); ctx.setLineDash([]);
    ctx.beginPath(); ctx.arc(p[0], p[1], r * .22, 0, 7); ctx.fillStyle = P.fill; ctx.fill();
    ctx.globalAlpha = isMain ? .85 : .6; ctx.fillStyle = C.boardInk; ctx.font = '700 ' + Math.round(cell * .34) + 'px Verdana, sans-serif'; ctx.fillText(String.fromCharCode(65 + ix), p[0] + r * .62, p[1] - r * .62); ctx.globalAlpha = 1; });
}

// A player's colour as a stone on a wood tile, drawn on a canvas like the board. Canvas pixels
// are left alone by dark-mode extensions, which repaint CSS colours and turned White's swatch dark.
export function drawSwatch(ctx: CanvasRenderingContext2D, size: number, p: number) {
  const P = PLAYERS[p]; ctx.clearRect(0, 0, size, size);
  ctx.fillStyle = C.board; ctx.beginPath(); ctx.roundRect(0, 0, size, size, size * .2); ctx.fill();
  ctx.beginPath(); ctx.arc(size / 2, size / 2, size * .34, 0, 7); ctx.fillStyle = P.fill; ctx.fill(); ctx.lineWidth = Math.max(1, size * .06); ctx.strokeStyle = P.rim; ctx.stroke();
}
