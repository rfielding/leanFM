// Requirement refs: property:session type panel; proof:the session type panel never misleads.
//
// A panel that stays closed until opened: GoServer's session type as LeanFM draws it, with the
// text it was drawn from and what the picture answers. Both files are generated from
// spec/Session.lean by spec/SessionPanel.lean; nothing here is drawn by hand. They load only
// when the panel is first opened.
import {useState} from 'react';

type Provenance = {question: string; eventSource: string; reducer: string; unit: string; boundary: string; protocol: string};

export function SessionTypePanel() {
  const [text, setText] = useState<string | null>(null), [prov, setProv] = useState<Provenance | null>(null), [error, setError] = useState('');
  const load = async (open: boolean) => {
    if (!open || text !== null) return;
    try {
      const [t, p] = await Promise.all([fetch('./session/goserver.leanfm').then(r => r.text()), fetch('./session/provenance.json').then(r => r.json())]);
      setText(t); setProv(p);
    } catch { setError('The session type could not be loaded.'); }
  };
  return (
    <details className="session-type" onToggle={e => void load((e.currentTarget as HTMLDetailsElement).open)}>
      <summary>Session type of GoServer</summary>
      {error ? <p className="danger">{error}</p> : null}
      {prov ? <p className="muted small">{prov.question} Drawn by LeanFM from {prov.eventSource}; {prov.reducer}. Shows {prov.unit}, for {prov.boundary}.</p> : null}
      <div className="session-figure"><img src="./session/goserver.svg" alt="Sequence diagram of the GoServer session type" loading="lazy" /></div>
      {text !== null ? <details className="session-text"><summary>Session type text</summary><pre>{text}</pre></details> : null}
    </details>
  );
}
