// Requirement refs: property:Browser navigation reflects server state; proof:Browser never fabricates
// destinations or crosses scopes; grammar:create_room, list_rooms, enter_room.
//
// The page: a name form until there is a session, then one tab per open room plus a Rooms tab
// for finding and creating rooms. Each room stays mounted while its tab is open.
import {useEffect, useRef, useState} from 'react';
import {api, auth, changePassword, claimName, feedback, issueSession, nextID, onFeedback, releaseName, signOut, storage} from '../api';
import {Tabs} from './common';
import {RoomView} from './Room';
import {RankingView} from './Ranking';

const BROWSE = '__rooms';
const RANKING = '__ranking';

export function App() {
  const [session, setSession] = useState(auth.session);
  const [note, setNote] = useState({text: '', error: false});
  useEffect(() => onFeedback(setNote), []);
  useEffect(() => { const n = storage.getItem('goserver:notice'); if (!session && n) { feedback(n); storage.setItem('goserver:notice', ''); } }, []);
  return (
    <>
      <header className="topbar"><div className="brand"><span className="brandstone" aria-hidden="true" /><strong>GoServer</strong><span className="tag">N-player Go</span></div>
        <span className="identity-label">{session ? <>{auth.identity + (auth.claimed ? ' · claimed' : ' · guest')} <button type="button" className="subtle sign-out" onClick={() => void signOut()}>Sign out</button></> : 'Choose a local name to join'}</span></header>
      <main>
        {!session ? <Welcome onSignedIn={() => setSession(auth.session)} /> : null}
        <p className="notice">Local preview · rooms, challenges and games reset when the app restarts; claimed names and the ranking are kept.</p>
        <div className={'feedback' + (note.error ? ' error' : '')} role="status" aria-live="polite">{note.text}</div>
        {session ? <Rooms /> : null}
      </main>
      <footer>GoServer · A room for every conversation.</footer>
    </>
  );
}

// The sign-in form: a name alone signs in as a guest; one password signs in to a claimed
// name; the same new password twice claims an unclaimed name. Changing the password and
// releasing the name sit in a panel that stays closed until opened.
function Welcome({onSignedIn}: {onSignedIn: () => void}) {
  const ref = useRef<HTMLInputElement>(null), pass = useRef<HTMLInputElement>(null), again = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { const last = storage.getItem('goserver:lastName'); if (last && ref.current) { ref.current.value = last; ref.current.focus(); } }, []);
  const name = () => (ref.current?.value || '').trim();
  const run = async (action: () => Promise<string | void>, clear: (HTMLInputElement | null)[]) => {
    if (busy) return; setBusy(true);
    try { const done = await action(); if (done) feedback(done); }
    catch (err: any) { feedback(err.message, true); }
    finally { clear.forEach(i => { if (i) i.value = ''; }); setBusy(false); }
  };
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const p = pass.current?.value || '', p2 = again.current?.value || '';
    void run(async () => {
      if (!name()) throw new Error('Enter a name.');
      if (p2 && p !== p2) throw new Error('The two passwords differ. To sign in, fill only the first one.');
      if (p2) { await claimName(name(), p); onSignedIn(); return 'The name ' + auth.identity + ' is yours now. Sign in with this password from now on.'; }
      await issueSession(name(), p); onSignedIn(); return 'Welcome, ' + auth.identity + '. Choose a room or create your own.';
    }, [pass.current, again.current]);
  };
  return (
    <section className="welcome"><div><p className="eyebrow">A PLACE TO MEET AND PLAY</p><h1>Find your room.<br />Make a challenge.</h1>
      <p>Two to eight players on one board. Score is territory minus the stones you lose. Empty seats are played by the server's search bots.</p></div>
      <div className="session-card">
        <form className="session-form" onSubmit={submit}>
          <label>Name<input ref={ref} className="identity" maxLength={128} required autoComplete="username" placeholder="Choose a name" /></label>
          <label>Password <span className="hint">empty: play as a guest</span><input ref={pass} className="password" type="password" maxLength={128} autoComplete="current-password" /></label>
          <label>Repeat password <span className="hint">only to claim a new name</span><input ref={again} className="password-again" type="password" maxLength={128} autoComplete="new-password" /></label>
          <button type="submit" disabled={busy}>Enter GoServer</button></form>
        <ManageName name={name} run={run} onSignedIn={onSignedIn} busy={busy} />
      </div>
    </section>
  );
}

function ManageName({name, run, onSignedIn, busy}: {name: () => string; run: (a: () => Promise<string | void>, clear: (HTMLInputElement | null)[]) => Promise<void>; onSignedIn: () => void; busy: boolean}) {
  const cur = useRef<HTMLInputElement>(null), next = useRef<HTMLInputElement>(null), next2 = useRef<HTMLInputElement>(null);
  const rel = useRef<HTMLInputElement>(null), sure = useRef<HTMLInputElement>(null);
  const change = (e: React.FormEvent) => {
    e.preventDefault();
    void run(async () => {
      if (!name()) throw new Error('Enter the name above first.');
      if ((next.current?.value || '') !== (next2.current?.value || '')) throw new Error('The two new passwords differ.');
      await changePassword(name(), cur.current?.value || '', next.current?.value || ''); onSignedIn();
      return 'Password changed for ' + auth.identity + '. Any other session for the name was signed out.';
    }, [cur.current, next.current, next2.current]);
  };
  const release = (e: React.FormEvent) => {
    e.preventDefault();
    void run(async () => {
      if (!name()) throw new Error('Enter the name above first.');
      if (!sure.current?.checked) throw new Error('Tick the box to confirm the release.');
      await releaseName(name(), rel.current?.value || '');
      if (sure.current) sure.current.checked = false;
      return 'Released ' + name() + '. Anyone may use or claim it now, and it has left the ranking.';
    }, [rel.current]);
  };
  return (
    <details className="manage-name">
      <summary>Manage a claimed name</summary>
      <p className="hint">Uses the name entered above.</p>
      <form className="change-password" onSubmit={change}><h3>Change password</h3>
        <label>Current password<input ref={cur} type="password" maxLength={128} required autoComplete="current-password" /></label>
        <label>New password<input ref={next} type="password" minLength={8} maxLength={128} required autoComplete="new-password" /></label>
        <label>Repeat new password<input ref={next2} type="password" minLength={8} maxLength={128} required autoComplete="new-password" /></label>
        <button type="submit" disabled={busy}>Change password</button></form>
      <form className="release-name" onSubmit={release}><h3>Release name</h3>
        <p className="hint">The name becomes free for anyone and leaves the ranking. Your games still count for the other players.</p>
        <label>Password<input ref={rel} type="password" maxLength={128} required autoComplete="current-password" /></label>
        <label className="check"><input ref={sure} type="checkbox" /> I want to give up this name</label>
        <button type="submit" className="danger" disabled={busy}>Release name</button></form>
    </details>
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
    {id: BROWSE, label: '+ Rooms', data: {'data-room': BROWSE}}, {id: RANKING, label: 'Ranking', data: {'data-room': RANKING}}];
  return (
    <div className="workspace">
      <Tabs tabs={tabs} active={active} onSelect={setActive} onClose={closeRoom} label="Rooms" className="room-tabs" />
      {active === BROWSE ? <RoomBrowser openRooms={open} onOpen={openRoom} /> : null}
      {active === RANKING ? <RankingView /> : null}
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
