// The board canvas, the pointer preview, navigation, next-move chips and the game tree.
import {useEffect, useLayoutEffect, useRef, useState} from 'react';
import {C, PLAYERS, drawBoard, geomOf, xy} from '../game/draw';
import type {GameCtl} from '../game/game';
import {Stone, useCtl} from './common';

export function BoardCanvas({g}: {g: GameCtl}) {
  useCtl(g);
  const ref = useRef<HTMLCanvasElement>(null), [size, setSize] = useState(0);
  useEffect(() => { const c = ref.current; if (!c) return; const ro = new ResizeObserver(() => setSize(c.getBoundingClientRect().width)); ro.observe(c); return () => ro.disconnect(); }, []);
  useLayoutEffect(() => {
    const cv = ref.current; if (!cv || !size) return; const dpr = window.devicePixelRatio || 1;
    if (cv.width !== Math.round(size * dpr)) { cv.width = Math.round(size * dpr); cv.height = Math.round(size * dpr); }
    const x = cv.getContext('2d'); if (!x) return; x.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (!g.root) { x.fillStyle = C.wall; x.fillRect(0, 0, size, size); x.fillStyle = C.wallInk; x.font = '700 20px Verdana, sans-serif'; x.textAlign = 'center'; x.fillText(g.gs ? 'The board appears when the game starts.' : '', size / 2, size / 2); return; }
    drawBoard(g.G, x, size, g.cur, {territory: g.territory, heat: g.heatFor(g.cur), last: true, markers: true});
    const can = g.hoverPt >= 0 && g.canPlaceAt(g.cur, g.hoverPt);
    cv.style.cursor = g.hoverPt < 0 ? '' : can ? 'pointer' : 'not-allowed';
    if (can) { // the stone a click would place: the mover's colour, translucent, drawn only here and never sent anywhere
      const gm = geomOf(g.G, size), p = xy(g.G, g.hoverPt, gm), P = PLAYERS[g.cur.state.toMove], r = gm.cell * .46;
      x.globalAlpha = .55; x.beginPath(); x.arc(p[0], p[1], r, 0, 7); x.fillStyle = P.fill; x.fill(); x.lineWidth = Math.max(1.5, gm.cell * .06); x.strokeStyle = P.rim; x.stroke(); x.globalAlpha = 1;
    }
  });
  const pointAt = (e: React.PointerEvent | React.MouseEvent) => {
    const cv = ref.current; if (!cv || !g.G) return -1; const rc = cv.getBoundingClientRect(), gm = geomOf(g.G, rc.width);
    const x = Math.round((e.clientX - rc.left - gm.off) / gm.cell), y = Math.round((e.clientY - rc.top - gm.off) / gm.cell);
    return x < 0 || y < 0 || x >= g.G.N || y >= g.G.N ? -1 : (y + 1) * g.G.W + x + 1;
  };
  return <canvas ref={ref} className="board" aria-label="Go board"
    onPointerMove={e => { if (g.root && e.pointerType !== 'touch') g.setHover(pointAt(e)); }}
    onPointerLeave={() => g.setHover(-1)}
    onClick={e => { const m = pointAt(e); if (m >= 0) g.clickPoint(m); }} />;
}

export function NavBar({g}: {g: GameCtl}) {
  useCtl(g); const cur = g.cur, p = cur?.parent, i = p ? p.children.indexOf(cur) : 0, none = !g.root;
  return (
    <div className="navbar">
      <div className="navbtns" role="group" aria-label="Walk the game tree">
        <button className="sq nav-home" type="button" title="Start (Home)" disabled={none || !p} onClick={() => g.home()}>|◀</button>
        <button className="sq nav-back" type="button" title="Back (←)" disabled={none || !p} onClick={() => g.back()}>◀</button>
        <button className="sq nav-fwd" type="button" title="Forward on the chosen line (→)" disabled={none || !cur.children.length} onClick={() => g.fwd()}>▶</button>
        <button className="sq nav-end" type="button" title="End of line (End)" disabled={none || !cur.children.length} onClick={() => g.end()}>▶|</button>
        <button className="sq nav-up" type="button" title={cur && cur.children.length > 1 ? 'Choose the previous next move (↑)' : 'Previous variation (↑)'} disabled={none || !g.canUpDown(-1)} onClick={() => g.upDown(-1)}>▲</button>
        <button className="sq nav-down" type="button" title={cur && cur.children.length > 1 ? 'Choose the next next move (↓)' : 'Next variation (↓)'} disabled={none || !g.canUpDown(1)} onClick={() => g.upDown(1)}>▼</button>
        <button className="sq live nav-live" type="button" title="Back to the live game (L)" disabled={none || cur === g.live} onClick={() => g.toLive()}>Live</button>
      </div>
      <div className="chips"><span className="lab">Next</span>
        {!g.root ? null : !cur.children.length ? <span className="muted small">{cur === g.live ? 'This is the live position.' : 'No continuation yet.'}</span> :
          cur.children.map((c: any, k: number) => (
            <button key={c.id} type="button" className={'chip' + (k === cur.main ? ' main' : '') + (c.local ? ' local' : '')} onClick={() => { cur.main = k; g.go(c); }}>
              {String.fromCharCode(65 + k)} <Stone p={c.player} size={18} /> {g.coord(c.move)}
            </button>))}
      </div>
    </div>
  );
}

export function GameTree({g}: {g: GameCtl}) {
  useCtl(g); const box = useRef<HTMLDivElement>(null);
  const root = g.root, cur = g.cur;
  const dx = 18, dy = 24, pad = 14; let maxRow = 0, maxD = 0; const list: any[] = [];
  if (root) (function lay(n: any, r: number) { n._r = r; if (r > maxRow) maxRow = r; if (n.depth > maxD) maxD = n.depth; list.push(n); n.children.forEach((c: any, i: number) => lay(c, i === 0 ? r : maxRow + 1)); })(root, 0);
  const onPath = new Set<number>(); for (let p = cur; p; p = p.parent) onPath.add(p.id);
  const W = pad * 2 + maxD * dx, H = pad * 2 + maxRow * dy, X = (n: any) => pad + n.depth * dx, Y = (n: any) => pad + n._r * dy;
  useEffect(() => { const b = box.current; if (!b || !cur) return; const cx = X(cur), cy = Y(cur);
    if (cx < b.scrollLeft + 20 || cx > b.scrollLeft + b.clientWidth - 20) b.scrollLeft = cx - b.clientWidth / 2;
    if (cy < b.scrollTop + 20 || cy > b.scrollTop + b.clientHeight - 20) b.scrollTop = cy - b.clientHeight / 2; });
  const pick = (e: React.MouseEvent) => { const id = (e.target as Element).getAttribute?.('data-id'); if (!id) return; const n = g.nodeById(+id); if (n) g.jump(n); };
  return (
    <div className="treebox" ref={box} aria-label="Game tree: filled dots are the real game, hollow dots are variations">
      {root ? <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} onClick={pick}>
        {list.filter(n => n.parent).map(n => { const on = onPath.has(n.id); return <path key={'e' + n.id} d={'M' + X(n.parent) + ' ' + Y(n.parent) + (n._r !== n.parent._r ? ' V' + Y(n) + ' H' + X(n) : ' H' + X(n))} fill="none" stroke={on ? C.ink : C.rule} strokeWidth={on ? 2.5 : 1.5} strokeDasharray={n.local ? '4 3' : 'none'} />; })}
        {list.map(n => { const x = X(n), y = Y(n), P = PLAYERS[n.player], t = n.parent ? g.seatName(n.player) + ' ' + g.coord(n.move) + ' (move ' + n.depth + (n.local ? ', variation' : '') + ')' : 'Start';
          return <g key={'n' + n.id}>
            {n === cur ? <circle cx={x} cy={y} r={10} fill="none" stroke={C.accent} strokeWidth={3} /> : null}
            {n === g.live ? <circle cx={x} cy={y} r={13} fill="none" stroke={C.mark} strokeWidth={2} /> : null}
            {!n.parent ? <rect data-id={n.id} x={x - 6} y={y - 6} width={12} height={12} fill={C.muted}><title>{t}</title></rect>
              : n.move === RESIGN ? <rect data-id={n.id} x={x - 5.5} y={y - 5.5} width={11} height={11} fill={C.bg} stroke={P.fill} strokeWidth={2.5}><title>{t}</title></rect>
              : n.move < 0 ? <circle data-id={n.id} cx={x} cy={y} r={5.5} fill={C.bg} stroke={P.fill} strokeWidth={2.5}><title>{t}</title></circle>
              : <circle data-id={n.id} cx={x} cy={y} r={6.5} fill={n.local ? C.bg : P.fill} stroke={n.local ? P.fill : P.rim} strokeWidth={n.local ? 2.5 : 1.5}><title>{t}</title></circle>}
          </g>; })}
      </svg> : null}
    </div>
  );
}
