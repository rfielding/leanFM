// One open game: board column, play bar and side tabs. Mounted while its tab is open, hidden
// while another tab is shown, so variations and analysis survive switching tabs.
import {useEffect, useRef, useState} from 'react';
import {api, auth, feedback, nextID, storage} from '../api';
import type {GameCtl} from '../game/game';
import {BoardCanvas, GameTree, NavBar} from './Board';
import {ChatForm, ChatList, Tabs, useCtl, type ChatItem} from './common';
import {GifPanel, PlayBar, ScoresPanel, SearchPanel, SeatsPanel} from './Panels';
import {SessionTypePanel} from './SessionType';

const SIDE = [{id: 'scores', label: 'Scores'}, {id: 'search', label: 'Search'}, {id: 'seats', label: 'Seats'}, {id: 'chat', label: 'Chat'}, {id: 'gif', label: 'GIF'}];

// Requirement refs: property:chat follows the tree. The remarks pinned to positions on the line
// from the empty board to the viewed position, in the order of that line, each tagged with its move.
export function alongLine(g: GameCtl, items: ChatItem[] | null): ChatItem[] | null {
  if (!items || !g.root) return items;
  const path = g.pathRefs(), here = g.chatNode();
  return items.map((it, i) => ({it, i, d: path.get(it.node || 'm0')})).filter(x => x.d !== undefined)
    .sort((a, b) => (a.d! - b.d!) || (a.i - b.i))
    .map(({it, d}) => ({...it, where: (it.node || 'm0') === here ? 'here' : d ? 'move ' + d : 'start'}));
}

export function useGameChat(gameId: string, active: boolean) {
  const [items, setItems] = useState<ChatItem[] | null>(null), [people, setPeople] = useState<string[]>([]);
  const load = async () => { const r = await api('game_history', {gameId}); if (r.gameId !== gameId) return; setItems(r.items || []); setPeople(r.participants || []); };
  useEffect(() => { let alive = true, t = 0;
    const loop = async () => { try { if (!document.hidden) await load(); } catch (e: any) { if (alive) feedback(e.message, true); } if (alive) t = window.setTimeout(loop, active ? 2500 : 6000); };
    void loop(); return () => { alive = false; clearTimeout(t); }; }, [gameId, active]);
  return {items, people, reload: load};
}

export function GamePanel({g, name, active, chat}: {g: GameCtl; name: string; active: boolean; chat: ReturnType<typeof useGameChat>}) {
  useCtl(g);
  const [tab, setTab] = useState(() => storage.getItem('goserver:sidetab') || 'scores'), seen = useRef(-1), opened = useRef(false);
  const pick = (t: string) => { setTab(t); storage.setItem('goserver:sidetab', t); };
  // Before the start the seat plan is what matters: open on Seats once, when the state first arrives.
  useEffect(() => { if (!opened.current && g.gs) { opened.current = true; if (g.gs.status === 'open') setTab('seats'); } });
  useEffect(() => { g.setActive(active); if (active) window.GameViewDebug = {...g.probes(), tab: () => tab, showTab: pick}; }, [active, tab]);
  const n = chat.items?.length || 0; if (chat.items && seen.current < 0) seen.current = n; if (tab === 'chat' && active) seen.current = n; if (n < seen.current) seen.current = n;
  const unread = Math.max(0, n - seen.current), mergeWaits = (g.gs?.proposals || []).some((p: any) => p.waitingFor.includes(auth.identity));
  // Arrow keys walk the tree for the visible game only.
  useEffect(() => {
    if (!active) return;
    const key = (e: KeyboardEvent) => {
      if (!g.root || e.ctrlKey || e.metaKey || e.altKey) return; const t = e.target as HTMLElement, tag = t.tagName, k = e.key;
      // typing goes to inputs; a focused tab keeps ←/→ for moving between tabs but every other key still works
      if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA' || (t.getAttribute('role') === 'tab' && k.startsWith('Arrow'))) return;
      if (k === 'ArrowLeft') { g.back(); e.preventDefault(); } else if (k === 'ArrowRight') { g.fwd(); e.preventDefault(); } else if (k === 'ArrowUp') { g.upDown(-1); e.preventDefault(); } else if (k === 'ArrowDown') { g.upDown(1); e.preventDefault(); }
      else if (k === 'Home') { g.home(); e.preventDefault(); } else if (k === 'End') { g.end(); e.preventDefault(); } else if (k === 'l' || k === 'L') g.toLive();
      else if ((k === 'c' || k === 'C') && g.analysisAllowed()) g.localSearch(g.cur, true); else if (k === 'p' || k === 'P') { g.pass(); e.preventDefault(); }
    };
    document.addEventListener('keydown', key); return () => document.removeEventListener('keydown', key);
  }, [active, g]);
  const gs = g.gs;
  const tabs = SIDE.map(t => ({...t, data: {'data-panel': t.id},
    badge: t.id === 'chat' && unread ? String(unread) : t.id === 'seats' && mergeWaits && tab !== 'seats' ? '!' : undefined}));
  return (
    <section className="game-panel" data-game={g.gameId} hidden={!active}>
      <div className="section-heading"><div><p className="eyebrow">CHALLENGE</p><h2 className="game-heading">{name}</h2>
        <p className="muted small">{gs ? gs.boardSize + '×' + gs.boardSize + ' · ' + gs.seats.length + ' players · by ' + gs.creator : 'Joining…'}{chat.people.length ? ' · in this challenge: ' + chat.people.join(', ') : ''}</p></div></div>
      <div className="lab">
        <div className="boardcol">
          <BoardCanvas g={g} />
          <NavBar g={g} />
          <GameTree g={g} />
          <div className="keys"><kbd>←</kbd> <kbd>→</kbd> step · <kbd>↑</kbd> <kbd>↓</kbd> choose among the next moves A, B… (or switch variation) · <kbd>L</kbd> live · <kbd>P</kbd> pass · <kbd>C</kbd> computer move. On your live turn a click or P plays in the game; once analysis is open to you (a finished game, or watching), a click, P or C plays for whichever seat is to move in the position you are viewing, as a variation.</div>
          <SessionTypePanel />
        </div>
        <div className="side">
          <PlayBar g={g} />
          <Tabs tabs={tabs} active={tab} onSelect={pick} label="Game panels" className="side-tabs" />
          <section className="box tabpanel" data-panel={tab} role="tabpanel">
            {tab === 'scores' ? <><h3>Scores and projections</h3><ScoresPanel g={g} /></> : null}
            {tab === 'search' ? <><h3>Search at this position</h3><SearchPanel g={g} /></> : null}
            {tab === 'seats' ? <><h3>Seats and teams</h3><SeatsPanel g={g} /></> : null}
            {tab === 'chat' ? <><h3>Challenge conversation</h3>
              <p className="small muted">Remarks belong to the position they were written at: this shows the ones along the line from the empty board to the position on the board{g.cur && g.cur.depth ? ' (move ' + g.cur.depth + ')' : ''}.</p>
              <ChatList items={alongLine(g, chat.items)} placeholder={chat.items && chat.items.length ? 'No remarks along this line up to here.' : 'This conversation is separate from the room.'} label="Challenge conversation" className="game-chat" />
              <ChatForm className="game-chat-form" label="Message this challenge" placeholder={g.cur && g.cur !== g.live ? 'Remark on move ' + g.cur.depth + '…' : 'Discuss your game…'} disabled={chat.items === null}
                onSend={async body => { try { await api('send_game_chat', {gameId: g.gameId, body, node: g.chatNode(), requestId: nextID()}); await chat.reload(); } catch (e: any) { feedback(e.message, true); throw e; } }} /></> : null}
            {tab === 'gif' ? <><h3>Animated GIF</h3><GifPanel g={g} /></> : null}
          </section>
        </div>
      </div>
    </section>
  );
}

