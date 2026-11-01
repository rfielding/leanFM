// Requirement refs: property:Browser navigation reflects server state; proof:Browser never fabricates
// destinations or crosses scopes; grammar:create_room, list_rooms, enter_room.
//
// The page: a name form until there is a session, then one tab per open room plus a Rooms tab
// for finding and creating rooms. Each room stays mounted while its tab is open.
import {useEffect, useRef, useState} from 'react';
import {api, auth, feedback, issueSession, nextID, onFeedback, storage} from '../api';
import {Tabs} from './common';
import {RoomView} from './Room';

const BROWSE = '__rooms';

export function App() {
  const [session, setSession] = useState(auth.session);
  const [note, setNote] = useState({text: '', error: false});
  useEffect(() => onFeedback(setNote), []);
  useEffect(() => { const n = storage.getItem('goserver:notice'); if (!session && n) { feedback(n); storage.setItem('goserver:notice', ''); } }, []);
  return (
    <>
      <header className="topbar"><div className="brand"><span className="brandstone" aria-hidden="true" /><strong>GoServer</strong><span className="tag">N-player Go</span></div>
        <span className="identity-label">{session ? auth.identity : 'Choose a local name to join'}</span></header>
      <main>
        {!session ? <Welcome onSignedIn={() => setSession(auth.session)} /> : null}
        <p className="notice">Local preview · rooms, challenges and games reset when the app restarts.</p>
        <div className={'feedback' + (note.error ? ' error' : '')} role="status" aria-live="polite">{note.text}</div>
        {session ? <Rooms /> : null}
      </main>
      <footer>GoServer · A room for every conversation.</footer>
    </>
  );
}

function Welcome({onSignedIn}: {onSignedIn: () => void}) {
  const ref = useRef<HTMLInputElement>(null), [busy, setBusy] = useState(false);
  useEffect(() => { const last = storage.getItem('goserver:lastName'); if (last && ref.current) { ref.current.value = last; ref.current.focus(); } }, []);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault(); if (busy || !ref.current) return; setBusy(true);
    const name = ref.current.value.trim();
    try { await issueSession(name); onSignedIn(); feedback('Welcome, ' + name + '. Choose a room or create your own.'); }
    catch (err: any) { feedback(err.message, true); } finally { setBusy(false); }
  };
  return (
    <section className="welcome"><div><p className="eyebrow">A PLACE TO MEET AND PLAY</p><h1>Find your room.<br />Make a challenge.</h1>
      <p>Two to eight players on one board. Score is territory minus the stones you lose. Empty seats are played by the server's search bots.</p></div>
      <form className="session-form" onSubmit={submit}><label>Your local display name<input ref={ref} className="identity" maxLength={128} required autoComplete="nickname" placeholder="Choose a name" /></label>
        <button type="submit" disabled={busy}>Enter GoServer</button></form>
    </section>
  );
}

function Rooms() {
  const key = 'goserver:rooms:' + auth.identity;
  const [open, setOpen] = useState<string[]>(() => { try { const v = JSON.parse(storage.getItem(key) || '[]'); return v.length ? v : ['lobby']; } catch { return ['lobby']; } });
  const [active, setActive] = useState<string>(() => storage.getItem(key + ':active') || open[0] || BROWSE);
  const [unread, setUnread] = useState<Record<string, number>>({});
  useEffect(() => { storage.setItem(key, JSON.stringify(open)); storage.setItem(key + ':active', active); }, [open, active]);
  const openRoom = (id: string) => { setOpen(o => o.includes(id) ? o : [...o, id]); setActive(id); };
  const closeRoom = (id: string) => { setOpen(o => { const n = o.filter(x => x !== id); if (active === id) setActive(n[n.length - 1] || BROWSE); return n; }); };
  const tabs = [...open.map(id => ({id, label: '# ' + id, badge: unread[id] && id !== active ? String(unread[id]) : undefined, closable: true, data: {'data-room': id}})),
    {id: BROWSE, label: '+ Rooms', data: {'data-room': BROWSE}}];
  return (
    <div className="workspace">
      <Tabs tabs={tabs} active={active} onSelect={setActive} onClose={closeRoom} label="Rooms" className="room-tabs" />
      {active === BROWSE ? <RoomBrowser openRooms={open} onOpen={openRoom} /> : null}
      {open.map(id => <RoomView key={id} roomId={id} active={active === id} onUnread={n => setUnread(u => u[id] === n ? u : {...u, [id]: n})} />)}
    </div>
  );
}

function RoomBrowser({openRooms, onOpen}: {openRooms: string[]; onOpen: (id: string) => void}) {
  const [rooms, setRooms] = useState<string[] | null>(null), ref = useRef<HTMLInputElement>(null), busy = useRef(false);
  const load = async () => { const r = await api('list_rooms', {requestId: nextID()}); setRooms(r.roomIds || []); };
  useEffect(() => { let alive = true, t = 0; const loop = async () => { try { await load(); } catch (e: any) { if (alive) feedback(e.message, true); } if (alive) t = window.setTimeout(loop, 4000); }; void loop(); return () => { alive = false; clearTimeout(t); }; }, []);
  const create = async (e: React.FormEvent) => {
    e.preventDefault(); if (busy.current || !ref.current) return; busy.current = true;
    try { const r = await api('create_room', {roomName: ref.current.value, requestId: nextID()}); ref.current.value = ''; await load(); onOpen(r.roomId); feedback('Room created. Invite someone to join the conversation.'); }
    catch (err: any) { feedback(err.message, true); } finally { busy.current = false; }
  };
  return (
    <section className="panel room-browser">
      <div className="section-heading"><h2>Chat rooms</h2><button type="button" className="subtle" onClick={() => void load().catch(e => feedback(e.message, true))}>Refresh</button></div>
      <nav className="room-list" aria-label="Chat rooms">
        {rooms === null ? <p className="empty">Loading rooms…</p> : !rooms.length ? <p className="empty">No rooms yet. Create the first room.</p> :
          rooms.map(id => <button key={id} type="button" className={'room-button' + (openRooms.includes(id) ? ' active' : '')} data-room={id} onClick={() => onOpen(id)}>{id}{openRooms.includes(id) ? <span className="muted small"> · open</span> : null}</button>)}
      </nav>
      <form className="room-form" onSubmit={create}><label>Create a room<input ref={ref} className="room-name" maxLength={128} required placeholder="Room name" /></label><button type="submit">Create room</button></form>
    </section>
  );
}
