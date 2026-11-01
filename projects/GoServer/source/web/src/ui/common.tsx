// Shared building blocks: accessible tabs, stone swatches, chat, the controller hook.
import {useEffect, useLayoutEffect, useRef, useSyncExternalStore, type ReactNode} from 'react';
import {PLAYERS, drawSwatch} from '../game/draw';
import type {GameCtl} from '../game/game';

export function useCtl(g: GameCtl) { useSyncExternalStore(g.subscribe, g.getVersion); return g; }

// A player's colour: a stone on a wood tile, drawn on a canvas (see drawSwatch), with its name
// for screen readers and as a tooltip.
export function Stone({p, size = 24}: {p: number; size?: number}) {
  const ref = useRef<HTMLCanvasElement>(null);
  useLayoutEffect(() => { const c = ref.current; if (!c) return; const dpr = window.devicePixelRatio || 1; c.width = Math.round(size * dpr); c.height = Math.round(size * dpr); const x = c.getContext('2d'); if (!x) return; x.setTransform(dpr, 0, 0, dpr, 0, 0); drawSwatch(x, size, p); }, [p, size]);
  return <canvas ref={ref} className="stone-swatch" width={size} height={size} style={{width: size, height: size}} role="img" aria-label={PLAYERS[p].name} title={PLAYERS[p].name} />;
}

export interface TabSpec { id: string; label: ReactNode; badge?: ReactNode; attention?: boolean; closable?: boolean; data?: Record<string, string>; }

// A tab strip: buttons with role=tab; ←/→ move between tabs while one has focus; × closes.
export function Tabs({tabs, active, onSelect, onClose, label, className = ''}: {tabs: TabSpec[]; active: string; onSelect: (id: string) => void; onClose?: (id: string) => void; label: string; className?: string}) {
  const refs = useRef(new Map<string, HTMLButtonElement>());
  const key = (e: React.KeyboardEvent) => {
    const i = tabs.findIndex(t => t.id === active); let j = -1;
    if (e.key === 'ArrowRight') j = (i + 1) % tabs.length; else if (e.key === 'ArrowLeft') j = (i + tabs.length - 1) % tabs.length;
    if (j < 0) return; e.preventDefault(); e.stopPropagation(); onSelect(tabs[j].id); refs.current.get(tabs[j].id)?.focus();
  };
  return (
    <div className={'tabs ' + className} role="tablist" aria-label={label} onKeyDown={key}>
      {tabs.map(t => (
        <span key={t.id} className={'tabwrap' + (t.id === active ? ' on' : '')}>
          <button type="button" role="tab" ref={el => { if (el) refs.current.set(t.id, el); else refs.current.delete(t.id); }}
            aria-selected={t.id === active} tabIndex={t.id === active ? 0 : -1} onClick={() => onSelect(t.id)} {...(t.data || {})}>
            {t.label}{t.badge ? <span className={'badge' + (t.attention ? ' attention' : '')}>{t.badge}</span> : null}
          </button>
          {t.closable && onClose ? <button type="button" className="tabclose" aria-label={'Close ' + (typeof t.label === 'string' ? t.label : 'tab')} title="Close tab" onClick={() => onClose(t.id)}>×</button> : null}
        </span>
      ))}
    </div>
  );
}

export interface ChatItem { sender: string; timeMs: number; body: string; }

export function ChatList({items, placeholder, label, className}: {items: ChatItem[] | null; placeholder: string; label: string; className: string}) {
  const ref = useRef<HTMLOListElement>(null), pinned = useRef(true);
  const onScroll = () => { const n = ref.current; if (n) pinned.current = n.scrollHeight - n.scrollTop - n.clientHeight < 70; };
  useEffect(() => { const n = ref.current; if (n && pinned.current) n.scrollTop = n.scrollHeight; }, [items]);
  return (
    <ol ref={ref} className={'chat-list ' + className} aria-label={label} aria-live="polite" onScroll={onScroll}>
      {items === null ? <li className="empty">Loading…</li> : !items.length ? <li className="empty">{placeholder}</li> :
        items.map((it, i) => (
          <li key={i} className="chat-item"><div className="chat-meta"><strong>{it.sender}</strong> <time dateTime={new Date(it.timeMs).toISOString()}>{new Date(it.timeMs).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'})}</time></div><p>{it.body}</p></li>
        ))}
    </ol>
  );
}

export function ChatForm({label, placeholder, disabled, onSend, className}: {label: string; placeholder: string; disabled: boolean; onSend: (body: string) => Promise<void>; className: string}) {
  const ref = useRef<HTMLInputElement>(null), busy = useRef(false);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault(); const input = ref.current; if (!input || busy.current) return; busy.current = true;
    try { await onSend(input.value); input.value = ''; } catch { /* the sender reports */ } finally { busy.current = false; }
  };
  return (
    <form className={className} onSubmit={submit}><fieldset disabled={disabled}>
      <label>{label}<div className="composer"><input ref={ref} maxLength={4000} required placeholder={placeholder} autoComplete="off" /><button type="submit">Send</button></div></label>
    </fieldset></form>
  );
}
