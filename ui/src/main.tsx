import React, {
  FormEvent,
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import {createRoot} from "react-dom/client";
import {ApiError, api, formRequest} from "./api";
import type {GrammarExpr, Message, Project, Task} from "./types";

declare global { interface Window { mermaid?: any } }

type Phase = "chat" | "book" | "grammar" | "tasks" | "source";
type QuestionOption = {value: string; label: string; recommended?: boolean};
type ChatQuestion = {id: string; prompt: string; multiple?: boolean; options: QuestionOption[]};

function closeTruncatedJson(source: string): string {
  const open: string[] = [];
  let quoted = false, escaped = false;
  for (const character of source) {
    if (escaped) { escaped = false; continue; }
    if (quoted && character === "\\") { escaped = true; continue; }
    if (character === '"') { quoted = !quoted; continue; }
    if (quoted) continue;
    if (character === "{" || character === "[") open.push(character);
    else if (character === "}" && open.at(-1) === "{") open.pop();
    else if (character === "]" && open.at(-1) === "[") open.pop();
  }
  return source + open.reverse().map(character => character === "{" ? "}" : "]").join("");
}

function extractQuestions(text: string): {text: string; questions: ChatQuestion[]; invalid?: boolean} {
  const match = text.match(/```leanfm-(?:questions|qustions)\s*([\s\S]*?)```/i);
  if (!match) return {text, questions: []};
  const source = match[1].trim();
  for (const candidate of [...new Set([source, closeTruncatedJson(source)])]) {
    try {
      const parsed = JSON.parse(candidate);
      const questions = Array.isArray(parsed.questions) ? parsed.questions.filter((question: ChatQuestion) => question.id && question.prompt && Array.isArray(question.options)) : [];
      return {text: text.replace(match[0], "").trim(), questions};
    } catch { /* try the next bounded repair */ }
  }
  return {text: text.replace(match[0], "").trim(), questions: [], invalid: true};
}

function extractResult(text: string): {text: string; status?: "success" | "warn" | "fail"} {
  const match = text.match(/```leanfm-result\s*([\s\S]*?)```/i);
  if (!match) return {text};
  try {
    const status = JSON.parse(match[1]).status;
    return {text: text.replace(match[0], "").trim(), status: ["success", "warn", "fail"].includes(status) ? status : undefined};
  } catch { return {text}; }
}

function projectSvgPaths(text: string, projectId: string): string[] {
  const pattern = new RegExp(`(?:data/accounts/[^\\s]+/projects/${projectId}/)?(spec/images/[A-Za-z0-9._/-]+\\.svg)`, "gi");
  return [...text.matchAll(pattern)].map(match => match[1]).filter((path, index, paths) => paths.indexOf(path) === index);
}

type RemoteImage = {url: string; source: string; alt: string};
function remoteImages(text: string): RemoteImage[] {
  const found: RemoteImage[] = [];
  for (const match of text.matchAll(/!\[([^\]]*)\]\((https:\/\/[^)\s]+)\)/gi)) found.push({url: match[2], source: match[2], alt: match[1] || "Internet image"});
  for (const match of text.matchAll(/(https:\/\/commons\.wikimedia\.org\/wiki\/File(?:%3A|:)([^)\s]+))/gi)) {
    const filename = decodeURIComponent(match[2]);
    found.push({url: `https://commons.wikimedia.org/wiki/Special:Redirect/file/${encodeURIComponent(filename)}`, source: match[1], alt: filename});
  }
  return found.filter((image, index, images) => images.findIndex(other => other.url === image.url) === index);
}

function extractCanvases(text: string): {text: string; canvases: string[]} {
  const canvases: string[] = [];
  const remaining = text.replace(/```leanfm-canvas\s*([\s\S]*?)```/gi, (_block, source: string) => {
    canvases.push(source.trim());
    return "";
  });
  return {text: remaining.trim(), canvases};
}

function CanvasAnimation({source}: {source: string}) {
  const [running, setRunning] = useState(true), [revision, setRevision] = useState(0);
  const hasCanvas = /<canvas(?:\s|>)/i.test(source);
  if (!hasCanvas) return <div className="request-error"><div className="result-badge fail">FAIL</div><p>The canvas response did not contain a literal canvas element.</p></div>;
  const document = `<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="dark"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'"><style>html,body{margin:0;min-height:100%;overflow:hidden;background:#08141d;color:#e5edf3}body{display:grid;place-items:center}canvas{display:block;max-width:100%;height:auto}</style></head><body>${source}</body></html>`;
  function restart() { setRevision(value => value + 1); setRunning(true); }
  return <figure className="chat-canvas"><div className="chat-canvas-controls"><button onClick={() => setRunning(value => !value)}>{running ? "Stop" : "Start"}</button><button onClick={restart}>Restart</button></div>{running ? <iframe key={revision} title="Animated canvas response" sandbox="allow-scripts" srcDoc={document} /> : <div className="chat-canvas-stopped">Animation stopped</div>}</figure>;
}

function QuestionForm({questions, disabled, onAnswer}: {questions: ChatQuestion[]; disabled?: boolean; onAnswer: (answer: string) => void}) {
  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const complete = questions.every(question => (selected[question.id] || []).length > 0);
  function choose(question: ChatQuestion, value: string, checked: boolean) {
    setSelected(current => ({...current, [question.id]: question.multiple ? (checked ? [...(current[question.id] || []), value] : (current[question.id] || []).filter(item => item !== value)) : [value]}));
  }
  function submitAnswers() {
    const answer = questions.map(question => {
      const values = selected[question.id] || [];
      const labels = values.map(value => question.options.find(option => option.value === value)?.label || value);
      return `${question.prompt}\nAnswer: ${labels.join(", ")}`;
    }).join("\n\n");
    onAnswer(answer);
  }
  return <section className="chat-questions" aria-label="Questions requiring answers">{questions.map(question => <fieldset key={question.id}><legend>{question.prompt}</legend>{question.options.map(option => <label key={option.value} className={(selected[question.id] || []).includes(option.value) ? "selected" : ""}><input type={question.multiple ? "checkbox" : "radio"} name={question.id} value={option.value} checked={(selected[question.id] || []).includes(option.value)} onChange={event => choose(question, option.value, event.target.checked)} /> <span>{option.label}{option.recommended && <small>Recommended</small>}</span></label>)}</fieldset>)}<button className="primary" disabled={!complete || disabled} onClick={submitAnswers}>Submit answers</button></section>;
}

function Auth({onReady}: {onReady: () => void}) {
  const [register, setRegister] = useState(false), [error, setError] = useState("");
  const [username, setUsername] = useState(() => window.localStorage.getItem("leanfm:last-username") || "");
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setError(register ? "Verifying your API key…" : "");
    const data = Object.fromEntries(new FormData(event.currentTarget)) as Record<string, string>;
    try { await api(register ? "/api/accounts" : "/api/login", formRequest(data)); window.localStorage.setItem("leanfm:last-username", data.username); onReady(); }
    catch (e) { setError((e as Error).message); }
  }
  return <section className="auth"><div className="auth-card"><h1>LeanFM</h1><p>Use your own API key. This server has no platform key to bill.</p>
    <div className="auth-tabs"><button className={!register ? "active" : ""} onClick={() => setRegister(false)}>Log in</button><button className={register ? "active" : ""} onClick={() => setRegister(true)}>Create account</button></div>
    <form onSubmit={submit}><label>Username<input name="username" autoComplete="username" value={username} onChange={event => setUsername(event.target.value)} required /></label><label>Password<input name="password" type="password" autoComplete={register ? "new-password" : "current-password"} minLength={register ? 8 : undefined} required /></label>
      {register && <><label>Provider<select name="provider"><option value="openai">OpenAI</option></select></label><label>API key<input name="api_key" type="password" autoComplete="off" required /></label></>}
      <button className="primary">{register ? "Create account" : "Log in"}</button></form><div className="error">{error}</div></div></section>;
}

function Mermaid({source, className = "large-diagram"}: {source: string; className?: string}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    let current = true;
    if (!window.mermaid || !ref.current) return;
    window.mermaid.initialize({startOnLoad: false, theme: "dark", securityLevel: "strict"});
    window.mermaid.render(`leanfm-react-${Date.now()}-${Math.random().toString(16).slice(2)}`, source)
      .then(({svg}: {svg: string}) => { if (current && ref.current) ref.current.innerHTML = svg; })
      .catch((e: Error) => { if (current && ref.current) ref.current.textContent = `${e.message}\n\n${source}`; });
    return () => { current = false; };
  }, [source]);
  return <div ref={ref} className={className}><pre>{source}</pre></div>;
}

function MessageView({message, projectId, onDelete, onResend, onAnswer, disabled}: {message: Message; projectId: string; onDelete: () => void; onResend?: () => void; onAnswer?: (answer: string) => void; disabled?: boolean}) {
  const result = extractResult(message.text);
  const structured = extractQuestions(result.text);
  const canvasContent = extractCanvases(structured.text);
  const [answerText, activity] = canvasContent.text.split(/\n\nOperational trace:\n/, 2);
  const images = projectSvgPaths(answerText, projectId);
  const internetImages = remoteImages(answerText);
  const pieces = answerText.split(/```mermaid\s*\n?/i);
  const first = pieces.shift() || "";
  return <article className={`message ${message.role}`}>{result.status && <div className={`result-badge ${result.status}`}>{result.status.toUpperCase()}</div>}<div className="message-text">{first}{pieces.map((part, i) => {
    const end = part.indexOf("```");
    return end < 0 ? <React.Fragment key={i}>{`\`\`\`mermaid\n${part}`}</React.Fragment> : <React.Fragment key={i}><Mermaid source={part.slice(0, end).trim()} className="chat-diagram" />{part.slice(end + 3)}</React.Fragment>;
  })}</div>{structured.invalid && <div className="request-error"><div className="result-badge fail">FAIL</div><p>The model returned a malformed question form. Resend this message to retry.</p></div>}{canvasContent.canvases.map((source, index) => <CanvasAnimation source={source} key={index} />)}{images.map(path => <figure className="chat-inline-figure" key={path}><img src={`/api/projects/${projectId}/files/${path.split("/").map(encodeURIComponent).join("/")}`} alt={`Project figure ${path}`} /><figcaption>{path}</figcaption></figure>)}{internetImages.map(image => <figure className="chat-inline-figure" key={image.url}><img src={image.url} alt={image.alt} loading="lazy" referrerPolicy="no-referrer" /><figcaption><a href={image.source} target="_blank" rel="noreferrer noopener">Source: {image.source}</a></figcaption></figure>)}{activity && <details className="operational-trace"><summary>Operational trace</summary><pre>{activity}</pre></details>}{structured.questions.length > 0 && onAnswer && <QuestionForm questions={structured.questions} disabled={disabled} onAnswer={onAnswer} />}{message.usage && <div className="usage">{message.usage.input_tokens} input · {message.usage.cached_input_tokens} cached · {message.usage.output_tokens} output · {message.usage.total_tokens} total · billed to your API key</div>}
    <div className="message-actions">{onResend && <button onClick={onResend} disabled={disabled}>Resend</button>}<button onClick={onDelete}>Delete</button></div></article>;
}

function Chat({project}: {project: Project}) {
  const [messages, setMessages] = useState<Message[]>([]), [prompt, setPrompt] = useState(""), [busy, setBusy] = useState(false), [elapsedSeconds, setElapsedSeconds] = useState(0), [error, setError] = useState(""), [errorTrace, setErrorTrace] = useState("");
  useEffect(() => {
    if (!busy) { setElapsedSeconds(0); return; }
    const started = Date.now();
    setElapsedSeconds(0);
    const timer = window.setInterval(() => setElapsedSeconds(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => window.clearInterval(timer);
  }, [busy]);
  const elapsed = `${String(Math.floor(elapsedSeconds / 60)).padStart(2, "0")}:${String(elapsedSeconds % 60).padStart(2, "0")}`;
  async function load(signal?: AbortSignal) { const data = await api<{messages: Message[]}>(`/api/projects/${project.project_id}/conversation`, {}, signal); setMessages(data.messages || []); }
  useEffect(() => { const controller = new AbortController(); if (!project.read_only) load(controller.signal).catch(e => { if (e.name !== "AbortError") setError(e.message); }); return () => controller.abort(); }, [project.project_id]);
  async function submit(text: string) { if (!text.trim() || busy) return; text = text.trim(); setElapsedSeconds(0); setPrompt(""); setMessages(v => [...v, {message_id: "pending-user", role: "user", text}, {message_id: "pending", role: "assistant", text: "Agent running in the server launch directory… It may inspect files, apply edits, and run checks before replying."}]); setBusy(true); setError(""); setErrorTrace("");
    try { await api(`/api/projects/${project.project_id}/chat`, formRequest({prompt: text})); await load(); } catch (e) { setMessages(v => v.filter(message => message.message_id !== "pending" && message.message_id !== "pending-user")); setPrompt(text); setError((e as Error).message); if (e instanceof ApiError) setErrorTrace(JSON.stringify({...e.trace, project_id: project.project_id, prompt: text}, null, 2)); await load().catch(() => {}); } finally { setBusy(false); } }
  async function send(event: FormEvent) { event.preventDefault(); await submit(prompt); }
  async function remove(id: string) { if (!confirm("Delete this message from the project conversation?")) return; await api(`/api/projects/${project.project_id}/conversation/messages/${encodeURIComponent(id)}`, {method: "DELETE"}); await load(); }
  if (project.read_only) return <div className="empty"><div><h2>Read-only workspace</h2><p>Select an editable project to chat.</p></div></div>;
  return <section className="pane chat-pane">
    <div className="messages">{messages.length ? messages.map(m => <MessageView key={m.message_id} message={m} projectId={project.project_id} onDelete={() => remove(m.message_id)} onResend={m.role === "user" ? () => submit(m.text) : undefined} onAnswer={m.role === "assistant" ? submit : undefined} disabled={busy} />) : <div className="empty"><div><h2>What are we building?</h2><p>Start informally. LeanFM will grow the book and specifications with you.</p></div></div>}{error && <div className="request-error"><div className="result-badge fail">FAIL</div><p className="error">{error}</p>{errorTrace && <details><summary>Development trace</summary><button onClick={() => navigator.clipboard.writeText(errorTrace)}>Copy trace</button><pre>{errorTrace}</pre></details>}</div>}</div>
    <div className="composer-wrap">{busy && <div className="agent-running" role="status"><span className="agent-running-dot" />Agent running <time>{elapsed}</time></div>}<form className="composer" onSubmit={send}><textarea value={prompt} onChange={e => setPrompt(e.target.value)} placeholder="What are you trying to build?" disabled={busy} /><button disabled={busy}>Send</button></form></div></section>;
}

function Book({project}: {project: Project}) {
  const [source, setSource] = useState(""), [status, setStatus] = useState("Loading book…"), [revision, setRevision] = useState(0), [dark, setDark] = useState(true);
  const [editorPercent, setEditorPercent] = useState(42), [previewOnly, setPreviewOnly] = useState(false);
  const workbenchRef = useRef<HTMLDivElement>(null), draggingRef = useRef(false);
  const resize = useCallback((event: PointerEvent) => {
    if (!draggingRef.current || !workbenchRef.current) return;
    const bounds = workbenchRef.current.getBoundingClientRect();
    setEditorPercent(Math.min(80, Math.max(15, ((event.clientX - bounds.left) / bounds.width) * 100)));
  }, []);
  const stopResize = useCallback(() => { draggingRef.current = false; document.body.classList.remove("resizing-book"); }, []);
  useEffect(() => {
    window.addEventListener("pointermove", resize);
    window.addEventListener("pointerup", stopResize);
    return () => { window.removeEventListener("pointermove", resize); window.removeEventListener("pointerup", stopResize); document.body.classList.remove("resizing-book"); };
  }, [resize, stopResize]);
  useEffect(() => { const controller = new AbortController(); api<{source: string}>(`/api/projects/${project.project_id}/book`, {}, controller.signal).then(d => { setSource(d.source); setStatus(project.read_only ? "Read-only book" : "book/main.tex · saved"); setRevision(Date.now()); }).catch(e => { if (e.name !== "AbortError") setStatus(e.message); }); return () => controller.abort(); }, [project.project_id]);
  async function save() { setStatus("Saving…"); await api(`/api/projects/${project.project_id}/book`, formRequest({source})); setStatus("Saved; PDF build required"); }
  async function build() { setStatus("Building PDFs…"); await api(`/api/projects/${project.project_id}/book`, formRequest({source})); await api(`/api/projects/${project.project_id}/book/build`, {method: "POST"}); setStatus("Book built successfully"); setRevision(Date.now()); }
  return <section className="pane book-pane"><header className="book-toolbar"><div><h1>Project book</h1><p>{status}</p></div><div>{!project.read_only && <><button onClick={save}>Save source</button><button className="primary" onClick={build}>Build &amp; preview</button></>}<button className={!dark ? "active" : ""} onClick={() => setDark(false)}>Light PDF</button><button className={dark ? "active" : ""} onClick={() => setDark(true)}>Dark PDF</button><button className={previewOnly ? "active" : ""} onClick={() => setPreviewOnly(value => !value)}>{previewOnly ? "Restore split" : "Maximize PDF"}</button></div></header>
    <div ref={workbenchRef} className={`book-workbench ${previewOnly ? "preview-only" : ""}`} style={!previewOnly ? {gridTemplateColumns: `minmax(240px, ${editorPercent}%) 8px minmax(320px, 1fr)`} : undefined}><textarea id="bookSource" value={source} onChange={e => setSource(e.target.value)} readOnly={project.read_only} spellCheck={false} /><div className="book-divider" role="separator" aria-label="Resize book source and PDF preview" aria-orientation="vertical" onPointerDown={event => { event.preventDefault(); draggingRef.current = true; document.body.classList.add("resizing-book"); }} /><iframe id="bookPreview" title="Project book PDF" src={`/api/projects/${project.project_id}/book/${dark ? "main-dark.pdf" : "main.pdf"}?revision=${revision}`} /></div></section>;
}

function GrammarNode({expr}: {expr: GrammarExpr}) {
  if (expr.kind === "event") return <div className="grammar-terminal message-node"><strong>{expr.message}</strong><span className="actors">{expr.src} → {expr.dst}</span></div>;
  if (expr.kind === "empty") return <div className="grammar-terminal">ε</div>;
  if (expr.kind === "ref") return <div className="grammar-terminal grammar-reference">↪ {expr.task}</div>;
  return <details className={`grammar-ast-node grammar-${expr.kind}`} open><summary>{expr.kind}{expr.predicate ? ` · ${expr.predicate}` : ""}</summary><div className="grammar-ast-children">{(expr.children || []).map((child, i) => <GrammarNode key={i} expr={child} />)}</div></details>;
}

function Specification({project, view}: {project: Project; view: "grammar" | "tasks"}) {
  const [tasks, setTasks] = useState<Task[]>([]), [selected, setSelected] = useState<string>(""), [kind, setKind] = useState("interaction"), [error, setError] = useState("");
  useEffect(() => { const controller = new AbortController(); api<{tasks: Task[]}>(`/api/projects/${project.project_id}/tasks`, {}, controller.signal).then(d => { setTasks(d.tasks || []); setSelected(d.tasks?.[0]?.id || ""); }).catch(e => { if (e.name !== "AbortError") setError(e.message); }); return () => controller.abort(); }, [project.project_id]);
  const task = tasks.find(t => t.id === selected);
  if (error) return <div className="empty"><p className="error">{error}</p></div>;
  if (!tasks.length) return <div className="empty"><div><h2>No accepted project {view === "grammar" ? "grammar" : "tasks"} yet</h2><p>Use guided Chat to develop this project's book and requirements.</p></div></div>;
  if (view === "grammar") return <section className="pane grammar-pane"><header className="grammar-header"><h1>{project.display_name} grammar</h1></header><div className="grammar-workbench"><nav className="grammar-task-list">{tasks.map(t => <details key={t.id} open><summary onClick={() => setSelected(t.id)}>{t.id} ::=</summary>{t.grammar && <GrammarNode expr={t.grammar} />}</details>)}</nav><aside className="grammar-inspector"><h2>{task?.title}</h2><p>{task?.id}</p></aside></div></section>;
  return <section className="pane diagrams-pane"><header className="diagrams-header"><h1>Tasks</h1><div className="diagram-kind">{[["interaction","Productions · interaction"],["state","States · state machine"],["properties","Properties · CTL"],["constraints","where_ · guards"]].map(([id,label]) => <button key={id} className={kind === id ? "active" : ""} onClick={() => setKind(id)}>{label}</button>)}</div></header><div className="diagrams-workbench"><nav className="diagram-task-list vertical-tabs">{tasks.map(t => <button key={t.id} className={`diagram-task ${selected === t.id ? "active" : ""}`} onClick={() => setSelected(t.id)}><strong>{t.title}</strong><span>{t.transitions.length} productions · {t.states.length} states</span></button>)}</nav><main className="diagram-stage"><h2>{task?.title}</h2>{task && (kind === "interaction" || kind === "state") && <Mermaid source={kind === "interaction" ? task.interaction_mermaid : task.state_mermaid} />}{task && kind === "properties" && task.properties.map(p => <article className="task-clause" key={p.name}><strong>{p.mode} · {p.name}</strong><pre>{p.expression}</pre></article>)}{task && kind === "constraints" && task.constraints.map((c,i) => <article className="task-clause" key={i}><strong>where_</strong><pre>{c}</pre></article>)}</main></div></section>;
}

function ProjectWorkspace({project}: {project: Project}) {
  const [phase, setPhase] = useState<Phase>("chat");
  return <main className="main"><header className="topbar"><strong>{project.display_name}</strong><nav className="phase-tabs"><div className="phase-group"><span>Early</span><div><button className={phase === "chat" ? "tab active" : "tab"} onClick={() => setPhase("chat")}>Chat</button><button className={phase === "book" ? "tab active" : "tab"} onClick={() => setPhase("book")}>Book</button></div></div><div className="phase-group"><span>Intermediate</span><div><button className={phase === "grammar" ? "tab active" : "tab"} onClick={() => setPhase("grammar")}>Grammar</button><button className={phase === "tasks" ? "tab active" : "tab"} onClick={() => setPhase("tasks")}>Tasks</button></div></div><div className="phase-group"><span>Late</span><button className={phase === "source" ? "tab active" : "tab"} onClick={() => setPhase("source")}>Source</button></div></nav></header>
    {phase === "chat" && <Chat project={project} />}{phase === "book" && <Book project={project} />}{phase === "grammar" && <Specification project={project} view="grammar" />}{phase === "tasks" && <Specification project={project} view="tasks" />}{phase === "source" && <div className="empty"><div><h1>Source</h1><p>Repository files, diffs, builds, tests, and logs will appear here.</p></div></div>}</main>;
}

function App() {
  const [user, setUser] = useState<string | null>(null), [checkingSession, setCheckingSession] = useState(true), [projects, setProjects] = useState<Project[]>([]), [selected, setSelected] = useState<string | null>(null), [authVersion, setAuthVersion] = useState(0), [newName, setNewName] = useState("");
  const [fontScale, setFontScale] = useState(() => {
    const stored = Number(window.localStorage.getItem("leanfm:font-scale") || "1");
    return Number.isFinite(stored) ? Math.max(.8, stored) : 1;
  });
  useEffect(() => {
    document.documentElement.style.setProperty("--font-scale", String(fontScale));
    window.localStorage.setItem("leanfm:font-scale", String(fontScale));
  }, [fontScale]);
  async function load() { const me = await api<{username: string}>("/api/me"); const data = await api<{projects: Project[]}>("/api/projects"); setUser(me.username); setProjects(data.projects || []); setSelected(current => (data.projects || []).some(p => p.project_id === current) ? current : (data.projects || []).find(p => !p.read_only)?.project_id || null); }
  useEffect(() => { setCheckingSession(true); load().catch(() => setUser(null)).finally(() => setCheckingSession(false)); }, [authVersion]);
  useEffect(() => {
    const requireAuthentication = () => { setUser(null); setProjects([]); setSelected(null); setCheckingSession(false); };
    window.addEventListener("leanfm:authentication-required", requireAuthentication);
    return () => window.removeEventListener("leanfm:authentication-required", requireAuthentication);
  }, []);
  if (checkingSession) return <main className="auth"><div className="auth-card"><h1>LeanFM</h1><p>Loading workspace…</p></div></main>;
  if (!user) return <Auth onReady={() => setAuthVersion(v => v + 1)} />;
  const project = projects.find(p => p.project_id === selected);
  async function create(event: FormEvent) { event.preventDefault(); const result = await api<{project_id: string}>("/api/projects", formRequest({display_name: newName})); setNewName(""); await load(); setSelected(result.project_id); }
  async function remove(item: Project) { const confirmation = prompt(`Type ${item.display_name} to permanently delete it:`); if (confirmation === null) return; await api(`/api/projects/${item.project_id}`, {method: "DELETE", headers: {"Content-Type":"application/x-www-form-urlencoded"}, body: new URLSearchParams({confirmation}).toString()}); if (selected === item.project_id) setSelected(null); await load(); }
  return <div className="app"><aside className="sidebar"><div className="brand">LeanFM</div><form onSubmit={create}><input value={newName} onChange={e => setNewName(e.target.value)} placeholder="New project name" required /><button className="new-project">＋ Add project</button></form><div className="tab-set-label">Projects</div><div className="projects vertical-tabs">{projects.map(item => <div className="project-row" key={item.project_id}><button className={`project ${selected === item.project_id ? "active" : ""}`} onClick={() => setSelected(item.project_id)}>{item.display_name}{item.read_only && <span className="project-kind">read-only</span>}</button>{!item.read_only && <button className="project-delete" onClick={() => remove(item)}>Delete</button>}</div>)}</div><div className="sidebar-footer"><div className="font-controls" aria-label="Font zoom"><button type="button" aria-label="Decrease font size" disabled={fontScale <= .8} onClick={() => setFontScale(value => Math.max(.8, Number((value - .1).toFixed(1))))}>−</button><output aria-live="polite">{Math.round(fontScale * 100)}%</output><button type="button" aria-label="Increase font size" onClick={() => setFontScale(value => Number((value + .1).toFixed(1)))}>＋</button></div><span>{user}</span></div></aside>{project ? <ProjectWorkspace key={`${user}:${project.project_id}`} project={project} /> : <main className="main"><div className="empty"><h2>Create or select a project</h2></div></main>}</div>;
}

createRoot(document.getElementById("root")!).render(<App />);
