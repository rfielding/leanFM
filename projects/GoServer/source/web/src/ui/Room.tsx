// Requirement refs: property:Browser navigation reflects server state; proof:Browser never fabricates
// destinations or crosses scopes; grammar:enter_room, list_games, create_game, join_game, room_chat.
//
// One open room: its own tab strip, with the room's Lobby (conversation, challenge list, new
// challenge) first and then one tab per open game. Every request carries this room's or game's
// ID and its result is applied only to that room's or game's component, so a late response can
// never land in another tab.
import {useEffect, useRef, useState} from 'react';
import {api, auth, feedback, nextID, storage} from '../api';
import {GameCtl} from '../game/game';
import {ChatForm, ChatList, Tabs, useCtl, type ChatItem} from './common';
import {GamePanel, useGameChat} from './Game';

interface OpenGame { id: string; name: string; }
const LOBBY = '__lobby';

function GameTabLabel({g, name, active}: {g: GameCtl; name: string; active: boolean}) {
  useCtl(g); const needs = !active && g.needsMe();
  return <>{name}{needs ? <span className="badge attention" title="Your move, or a merge waits for your answer">!</span> : null}</>;
}

function OpenGameView({g, name, active}: {g: GameCtl; name: string; active: boolean}) {
  const chat = useGameChat(g.gameId, active);
  return <GamePanel g={g} name={name} active={active} chat={chat} />;
}

export function RoomView({roomId, active, onUnread}: {roomId: string; active: boolean; onUnread: (n: number) => void}) {
  const key = 'goserver:games:' + auth.identity + ':' + roomId;
  const [entered, setEntered] = useState<'entering' | 'joined' | 'failed'>('entering');
  const [chat, setChat] = useState<ChatItem[] | null>(null), [games, setGames] = useState<any[] | null>(null);
  const [open, setOpen] = useState<OpenGame[]>(() => { try { return JSON.parse(storage.getItem(key) || '[]'); } catch { return []; } });
  const [tab, setTab] = useState(LOBBY);
  const ctls = useRef(new Map<string, GameCtl>()), seen = useRef(-1);
  const ctl = (id: string) => { let c = ctls.current.get(id); if (!c) { c = new GameCtl(id); ctls.current.set(id, c); c.start(); } return c; };
  useEffect(() => { storage.setItem(key, JSON.stringify(open)); }, [open]);
  useEffect(() => () => { ctls.current.forEach(c => c.stop()); }, []);

  const loadChat = async () => { const r = await api('room_history', {roomId}); if (r.roomId === roomId) setChat(r.items || []); };
  const loadGames = async () => { const r = await api('list_games', {roomId, requestId: nextID()}); if (r.roomId === roomId) setGames(r.games || []); };
  useEffect(() => {
    let alive = true, t = 0;
    const loop = async () => {
      try { if (entered === 'joined' && !document.hidden) await Promise.all([loadChat(), loadGames()]); } catch (e: any) { if (alive && active) feedback(e.message, true); }
      if (alive) t = window.setTimeout(loop, active ? 2500 : 6000);
    };
    if (entered === 'entering') {
      api('enter_room', {roomId, requestId: nextID()}).then(async () => { if (!alive) return; setEntered('joined'); await Promise.all([loadChat(), loadGames()]); }).catch((e: any) => { if (alive) { setEntered('failed'); feedback(e.message, true); } });
    } else void loop();
    return () => { alive = false; clearTimeout(t); };
  }, [entered, active, roomId]);

  // unread room messages while another room is shown
  // messages already there when the room opens count as read
  const n = chat?.length || 0; if (chat && seen.current < 0) seen.current = n; if (active && tab === LOBBY) seen.current = n; if (n < seen.current) seen.current = n;
  useEffect(() => { onUnread(Math.max(0, n - seen.current)); });

  const openGame = async (id: string, name: string) => {
    try {
      await api('join_game', {gameId: id, requestId: nextID()});
      setOpen(o => o.some(x => x.id === id) ? o : [...o, {id, name}]); setTab(id);
    } catch (e: any) { feedback(e.message, true); }
  };
  const closeGame = (id: string) => {
    ctls.current.get(id)?.stop(); ctls.current.delete(id);
    setOpen(o => o.filter(x => x.id !== id)); if (tab === id) setTab(LOBBY);
  };
  // reopened tabs (after a reload) join again before use
  useEffect(() => { if (entered !== 'joined') return; open.forEach(o => { void api('join_game', {gameId: o.id, requestId: nextID()}).catch(() => closeGame(o.id)); }); }, [entered]);

  const tabs = [{id: LOBBY, label: 'Lobby', data: {'data-game': LOBBY}}, ...open.map(o => ({id: o.id, label: <GameTabLabel g={ctl(o.id)} name={o.name} active={active && tab === o.id} />, closable: true, data: {'data-game': o.id}}))];
  return (
    <section className="room-panel" data-room={roomId} hidden={!active}>
      <Tabs tabs={tabs} active={tab} onSelect={setTab} onClose={closeGame} label={'Games in ' + roomId} className="game-tabs" />
      <div className="lobby" hidden={tab !== LOBBY}>
        <section className="panel conversation">
          <div className="section-heading"><div><p className="eyebrow">ROOM CONVERSATION</p><h2 className="room-heading">{roomId}</h2></div>
            <span className="tag room-state">{entered === 'joined' ? 'Joined' : entered === 'failed' ? 'Could not enter' : 'Entering…'}</span></div>
          <ChatList items={entered === 'joined' ? chat : null} placeholder="Start the conversation in this room." label="Room conversation" className="room-chat" />
          <ChatForm className="room-chat-form" label="Message this room" placeholder="Say hello…" disabled={entered !== 'joined'}
            onSend={async body => { try { await api('send_room_chat', {roomId, body, requestId: nextID()}); await loadChat(); } catch (e: any) { feedback(e.message, true); throw e; } }} />
        </section>
        <aside className="panel challenges">
          <div className="section-heading"><h2>Game challenges</h2><span className="tag challenge-count">{games ? games.length : 0}</span></div>
          <div className="challenge-list">
            {games === null ? <p className="empty">Loading challenges…</p> : !games.length ? <p className="empty">No challenges in this room yet. Create one below.</p> :
              games.map(gm => (
                <article key={gm.gameId} className={'challenge-card' + (open.some(o => o.id === gm.gameId) ? ' active' : '')} data-game={gm.gameId}>
                  <h3>{gm.gameName}</h3><p>{gm.boardSize}×{gm.boardSize} · {gm.seatsFilled}/{gm.seats} seated · by {gm.creator} · {gm.status}</p>
                  <button type="button" onClick={() => void openGame(gm.gameId, gm.gameName)}>{open.some(o => o.id === gm.gameId) ? 'Show challenge' : 'Open challenge'}</button>
                </article>))}
          </div>
          <NewChallenge disabled={entered !== 'joined'} roomId={roomId} onCreated={async (gm, sit) => {
            await loadGames(); await openGame(gm.gameId, gm.gameName);
            if (sit) { try { await api('take_seat', {gameId: gm.gameId, seat: 0, requestId: nextID()}); await ctl(gm.gameId).refresh(); } catch (e: any) { feedback(e.message, true); } }
            feedback('Challenge created in ' + roomId + '. Plan seats as Person or Bot and set teams; others in the room can open it and sit; press Start when ready.');
          }} />
        </aside>
      </div>
      {open.map(o => <OpenGameView key={o.id} g={ctl(o.id)} name={o.name} active={active && tab === o.id} />)}
    </section>
  );
}

function NewChallenge({disabled, roomId, onCreated}: {disabled: boolean; roomId: string; onCreated: (g: any, sit: boolean) => Promise<void>}) {
  const busy = useRef(false);
  const submit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault(); if (busy.current) return; busy.current = true;
    const f = new FormData(e.currentTarget), num = (k: string) => parseInt(String(f.get(k)), 10), form = e.currentTarget;
    try {
      const created = await api('create_game', {roomId, gameName: String(f.get('name') || '').trim(), boardSize: num('board'), seats: num('seats'), turnDeadlineMs: num('deadline'), botMs: num('bot'), koRule: num('ko'), exploreMilli: num('explore'), rewardMode: String(f.get('reward')), softness: num('softness'), requestId: nextID()});
      (form.elements.namedItem('name') as HTMLInputElement).value = '';
      await onCreated(created, f.get('sit') === 'on');
    } catch (err: any) { feedback(err.message, true); } finally { busy.current = false; }
  };
  return (
    <form className="challenge-form" onSubmit={submit}><fieldset disabled={disabled}>
      <label>New challenge<input name="name" maxLength={128} required placeholder="Give your challenge a name" /></label>
      <div className="grid2">
        <label>Board<select name="board" defaultValue="11">{[5, 7, 9, 11, 13, 19].map(n => <option key={n}>{n}</option>)}</select></label>
        <label>Players<select name="seats" defaultValue="4">{[2, 3, 4, 5, 6, 7, 8].map(n => <option key={n}>{n}</option>)}</select></label>
        <label>Human deadline<select name="deadline" defaultValue="60000">{[[10000, '10 s'], [15000, '15 s'], [30000, '30 s'], [60000, '1 min'], [120000, '2 min'], [240000, '4 min'], [480000, '8 min'], [960000, '16 min'], [1920000, '32 min'], [3840000, '64 min']].map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></label>
        <label>Bot deadline<select name="bot" defaultValue="1000">{[[250, '0.25 s'], [500, '0.5 s'], [1000, '1 s'], [2000, '2 s'], [4000, '4 s'], [8000, '8 s'], [16000, '16 s']].map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></label>
        <label>Ko rule<select name="ko" defaultValue="0"><option value="0">Auto (on for 2 players)</option><option value="2">Simple ko + superko</option><option value="1">Off</option></select></label>
        <label>Exploration C<select name="explore" defaultValue="700"><option value="500">0.5</option><option value="700">0.7</option><option value="1000">1.0</option><option value="1400">1.4</option></select></label>
        <label>Bot reward<select name="reward" defaultValue="margin"><option value="margin">Soft margin vs best rival</option><option value="win">Win / share win</option><option value="rank">Rank</option></select></label>
        <label>Margin softness<select name="softness" defaultValue="4"><option value="2">2</option><option value="4">4</option><option value="8">8</option></select></label>
        <label className="check"><input name="sit" type="checkbox" defaultChecked /> I will play</label>
      </div>
      <button type="submit">Create challenge</button>
    </fieldset></form>
  );
}
