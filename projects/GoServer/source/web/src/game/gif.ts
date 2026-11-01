// GIF export of the viewed line (the Lab's encoder).
import {C, PLAYERS, drawBoard} from './draw';
import type {GameCtl} from './game';

function hex(c: string) { c = c.replace('#', ''); return [parseInt(c.slice(0, 2), 16), parseInt(c.slice(2, 4), 16), parseInt(c.slice(4, 6), 16)]; }
function buildPalette(K: number) {
  const base = [C.bg, C.ink, C.muted, C.accent, C.board, C.grid, C.wall, C.wallInk, C.mark, C.boardInk]; for (let i = 1; i <= K; i++) base.push(PLAYERS[i].fill, PLAYERS[i].rim, PLAYERS[i].ink);
  const b = base.map(hex), pal: number[][] = [], seen = new Set<string>(); const addc = (c: number[]) => { const k = c.join(','); if (!seen.has(k) && pal.length < 256) { seen.add(k); pal.push(c); } }; b.forEach(addc);
  const blends = (a: number[], list: number[][], steps: number) => list.forEach(c => { for (let s = 1; s < steps; s++) { const t = s / steps; addc([0, 1, 2].map(j => Math.round(a[j] * (1 - t) + c[j] * t))); } });
  blends(hex(C.board), b, 7); blends(hex(C.bg), b, 6); blends(hex(C.wall), [hex(C.wallInk), hex(C.board)], 6); for (let i = 1; i <= K; i++) blends(hex(PLAYERS[i].fill), [hex(PLAYERS[i].rim), hex(PLAYERS[i].ink)], 5);
  return pal;
}
function lzw(idx: Uint8Array, minCode: number) {
  const out: number[] = []; let cur = 0, bits = 0; const clear = 1 << minCode, eoi = clear + 1; let size = minCode + 1, next = eoi + 1; const dict = new Map<number, number>();
  const emit = (c: number) => { cur |= c << bits; bits += size; while (bits >= 8) { out.push(cur & 255); cur >>>= 8; bits -= 8; } }; emit(clear); let pre = idx[0];
  for (let i = 1; i < idx.length; i++) { const k = idx[i], key = (pre << 8) | k, v = dict.get(key); if (v === undefined) { emit(pre); if (next === 4096) { emit(clear); dict.clear(); next = eoi + 1; size = minCode + 1; } else { if (next >= (1 << size)) size++; dict.set(key, next++); } pre = k; } else pre = v; }
  emit(pre); emit(eoi); if (bits > 0) out.push(cur & 255); return out;
}
function encodeGif(w: number, h: number, pal: number[][], frames: Uint8Array[], delays: number[]) {
  const b: number[] = []; const s16 = (v: number) => b.push(v & 255, (v >> 8) & 255); 'GIF89a'.split('').forEach(c => b.push(c.charCodeAt(0))); s16(w); s16(h); b.push(0xF7, 0, 0);
  for (let i = 0; i < 256; i++) { const c = pal[i] || [0, 0, 0]; b.push(c[0], c[1], c[2]); } b.push(0x21, 0xFF, 0x0B); 'NETSCAPE2.0'.split('').forEach(c => b.push(c.charCodeAt(0))); b.push(3, 1, 0, 0, 0);
  const chunks: Uint8Array[] = [new Uint8Array(b)];
  frames.forEach((f, fi) => { const hd = [0x21, 0xF9, 4, 0x04, delays[fi] & 255, (delays[fi] >> 8) & 255, 0, 0, 0x2C, 0, 0, 0, 0, w & 255, w >> 8, h & 255, h >> 8, 0, 8]; const data = lzw(f, 8), body: number[] = [];
    for (let p = 0; p < data.length; p += 255) { const n = Math.min(255, data.length - p); body.push(n); for (let q = 0; q < n; q++) body.push(data[p + q]); } body.push(0); chunks.push(new Uint8Array(hd), new Uint8Array(body)); });
  chunks.push(new Uint8Array([0x3B])); return new Blob(chunks as BlobPart[], {type: 'image/gif'});
}
function drawFrame(g: GameCtl, ctx: CanvasRenderingContext2D, S: number, hdr: number, node: any) {
  const G = g.G, K = g.K, f = Math.round(S * .036); ctx.fillStyle = C.bg; ctx.fillRect(0, 0, S, hdr); ctx.save(); ctx.translate(0, hdr); drawBoard(G, ctx, S, node, {territory: g.territory, heat: null, last: true, markers: false}); ctx.restore();
  const pad = Math.round(f * .7); ctx.textBaseline = 'middle'; ctx.textAlign = 'left'; ctx.font = '700 ' + Math.round(f * 1.1) + 'px Verdana, sans-serif'; ctx.fillStyle = C.ink;
  ctx.fillText(node === g.root ? 'Start' : 'Move ' + node.depth + '  ' + g.seatName(node.player) + ' ' + g.coord(node.move), pad, Math.round(f * 1.2));
  const sc = scoreState(G, node.state, false).scores, per = Math.min(K, 4), cw = (S - 2 * pad) / per;
  for (let p = 1; p <= K; p++) { const r = Math.floor((p - 1) / per), col = (p - 1) % per, x = pad + col * cw, y = Math.round(f * 2.1 + r * f * 1.9 + f * .95);
    ctx.beginPath(); ctx.arc(x + f * .5, y, f * .45, 0, 7); ctx.fillStyle = PLAYERS[p].fill; ctx.fill(); ctx.lineWidth = 1.5; ctx.strokeStyle = PLAYERS[p].rim; ctx.stroke();
    ctx.font = '700 ' + Math.round(f * 1.05) + 'px ui-monospace, monospace'; ctx.fillStyle = C.ink; ctx.fillText(sc[p] + '  lost ' + node.state.losses[p], x + f * 1.25, y); }
}
export async function makeGif(g: GameCtl, size: number, delayMs: number) {
  const K = g.K, path: any[] = []; for (let p = g.cur; p; p = p.parent) path.unshift(p);
  const S = size, f = Math.round(S * .036), rows = Math.ceil(K / Math.min(K, 4)), hdr = Math.round(f * 2.1 + rows * f * 1.9 + f * .4), H = S + hdr, oc = document.createElement('canvas'); oc.width = S; oc.height = H;
  const ctx = oc.getContext('2d', {willReadFrequently: true})!, pal = buildPalette(K), cache = new Int16Array(32768).fill(-1), frames: Uint8Array[] = [], delays: number[] = [], dly = Math.round(delayMs / 10);
  for (let i = 0; i < path.length; i++) {
    drawFrame(g, ctx, S, hdr, path[i]); const px = ctx.getImageData(0, 0, S, H).data, ix = new Uint8Array(S * H);
    for (let j = 0, o = 0; j < ix.length; j++, o += 4) { const r = px[o], gg = px[o + 1], b = px[o + 2], key = ((r >> 3) << 10) | ((gg >> 3) << 5) | (b >> 3); let v = cache[key];
      if (v < 0) { let best = 0, bd = 1e9; for (let q = 0; q < pal.length; q++) { const c = pal[q], dr = c[0] - r, dg = c[1] - gg, db = c[2] - b, dd = dr * dr * 2 + dg * dg * 4 + db * db * 3; if (dd < bd) { bd = dd; best = q; } } cache[key] = v = best; } ix[j] = v; }
    frames.push(ix); delays.push(i === path.length - 1 ? 250 : (i === 0 ? Math.max(dly, 60) : dly)); await new Promise(r => setTimeout(r, 0));
  }
  const blob = encodeGif(S, H, pal, frames, delays);
  return {url: URL.createObjectURL(blob), name: 'goserver-' + g.G.N + 'x' + g.G.N + '-' + K + 'p-move' + g.cur.depth + '.gif', frames: frames.length, kb: Math.round(blob.size / 1024), depth: g.cur.depth};
}
