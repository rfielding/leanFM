import React, {
  FormEvent,
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import {createRoot} from "react-dom/client";
import katex from "katex";
import {ApiError, api, formRequest, reportClientError, setClientDiagnosticProject} from "./api";
import type {Billing, GrammarExpr, Message, Project, ProjectMemory, Task} from "./types";

declare global { interface Window { mermaid?: any } }

type Phase = "chat" | "memory" | "book" | "grammar" | "tasks" | "source";
type QuestionOption = {value: string; label: string; recommended?: boolean};
type ChatQuestion = {id: string; prompt: string; multiple?: boolean; options: QuestionOption[]};
type QueuedPrompt = {id: string; text: string; model: string; pendingQuestion?: {id: string; promptLength: number; composerTextLength: number}};

type MathFragment = {source: string; display: boolean; raw: string};

class ClientFaultBarrier extends React.Component<{children: React.ReactNode}, {failed: boolean}> {
  state = {failed: false};
  static getDerivedStateFromError() { return {failed: true}; }
  componentDidCatch(error: Error, info: React.ErrorInfo) {
    const enriched = new Error(`${error.message}\nReact component stack:${info.componentStack}`);
    enriched.name = error.name;
    enriched.stack = `${error.stack || error.message}\nReact component stack:${info.componentStack}`;
    reportClientError("Rendering the LeanFM React application", enriched);
  }
  render() {
    if (this.state.failed) return <main className="auth"><div className="auth-card"><h1>LeanFM client error</h1><p>The browser fault was logged to the server for analysis. Reload the page to restart the client.</p></div></main>;
    return this.props.children;
  }
}

function delimitedMath(fragment: string): MathFragment | undefined {
  if (fragment.startsWith("$$") && fragment.endsWith("$$")) return {source: fragment.slice(2, -2), display: true, raw: fragment};
  if (fragment.startsWith("\\[") && fragment.endsWith("\\]")) return {source: fragment.slice(2, -2), display: true, raw: fragment};
  if (fragment.startsWith("\\(") && fragment.endsWith("\\)")) return {source: fragment.slice(2, -2), display: false, raw: fragment};
  if (fragment.startsWith("$") && fragment.endsWith("$")) return {source: fragment.slice(1, -1), display: false, raw: fragment};
  return undefined;
}

function LatexText({text}: {text: string}) {
  const codeAndProse = text.split(/(```[\s\S]*?```)/g);
  return <>{codeAndProse.map((section, sectionIndex) => {
    if (section.startsWith("```") && section.endsWith("```")) return <React.Fragment key={`code-${sectionIndex}`}>{section}</React.Fragment>;
    const fragments = section.split(/(\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([^\n]+?\\\)|\$(?!\s)[^$\n]+?(?<!\s)\$)/g);
    return <React.Fragment key={`text-${sectionIndex}`}>{fragments.map((fragment, fragmentIndex) => {
      const math = delimitedMath(fragment);
      if (!math) return <React.Fragment key={fragmentIndex}>{fragment}</React.Fragment>;
      try {
        const html = katex.renderToString(math.source, {displayMode: math.display, output: "mathml", throwOnError: true, trust: false, strict: "warn"});
        const Tag = math.display ? "div" : "span";
        return <Tag key={fragmentIndex} className={math.display ? "chat-math-display" : "chat-math-inline"} dangerouslySetInnerHTML={{__html: html}} />;
      } catch (error) {
        reportClientError("Rendering LaTeX in an assistant response", error);
        return <code key={fragmentIndex} className="chat-math-error" title={(error as Error).message}>{math.raw}</code>;
      }
    })}</React.Fragment>;
  })}</>;
}

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

function latestUnansweredQuestion(messages: Message[], answeredIds: Set<string>): ChatQuestion | undefined {
  for (const message of [...messages].reverse()) {
    if (message.role !== "assistant") continue;
    const questions = extractQuestions(message.text).questions;
    for (const question of questions.reverse()) {
      if (!answeredIds.has(question.id)) return question;
    }
  }
  return undefined;
}

function extractResult(text: string): {text: string; status?: "success" | "warn" | "fail"} {
  const match = text.match(/```leanfm-result\s*([\s\S]*?)```/i);
  if (!match) return {text};
  try {
    const status = JSON.parse(match[1]).status;
    return {text: text.replace(match[0], "").trim(), status: ["success", "warn", "fail"].includes(status) ? status : undefined};
  } catch { return {text}; }
}

function projectImagePaths(text: string, projectId: string): string[] {
  const pattern = new RegExp(`(?:data/accounts/[^\\s]+/projects/${projectId}/)?(spec/images/[A-Za-z0-9._/-]+\\.(?:svg|gif|png|jpe?g))`, "gi");
  return [...text.matchAll(pattern)].map(match => match[1]).filter(path => !path.includes(".."))
    .filter((path, index, paths) => paths.indexOf(path) === index);
}

function projectVideoPaths(text: string, projectId: string): string[] {
  const pattern = new RegExp(`(?:data/accounts/[^\\s]+/projects/${projectId}/)?((?:spec/images|spec/media|artifacts|renders)/[A-Za-z0-9._/-]+\\.(?:mp4|webm))`, "gi");
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

function CopyImageReference({reference}: {reference: string}) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(reference);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch (error) {
      reportClientError("Copying an image reference to the clipboard", error);
    }
  }
  return <button type="button" className="copy-image-reference" onClick={copy}>{copied ? "Copied" : "Copy reference"}</button>;
}

function ProjectImage({projectId, path}: {projectId: string; path: string}) {
  const [loaded, setLoaded] = useState(false), [missing, setMissing] = useState(false);
  const src = `/api/projects/${projectId}/files/${path.split("/").map(encodeURIComponent).join("/")}`;
  if (missing) return <div className="request-error"><div className="result-badge fail">FAIL</div><p>Referenced project image does not exist: {path}</p></div>;
  return <figure className="chat-inline-figure" style={!loaded ? {display: "none"} : undefined}><img src={src} alt={`Project figure ${path}`} onLoad={() => setLoaded(true)} onError={() => { setMissing(true); reportClientError("Loading a referenced project image", new Error(`Project image does not exist: ${path}`)); }} /><figcaption><span>{path}</span><CopyImageReference reference={path} /></figcaption></figure>;
}

function extractCanvases(text: string): {text: string; canvases: string[]} {
  const canvases: string[] = [];
  let remaining = text.replace(/```leanfm-canvas\s*([\s\S]*?)```/gi, (_block, source: string) => {
    canvases.push(source.trim());
    return "";
  });
  // Some providers occasionally spell out the requested fence marker instead
  // of emitting backticks. Recover only the tightly bounded canvas+script form;
  // arbitrary HTML remains ordinary escaped chat text.
  remaining = remaining.replace(/(?:^|\n)\s*(?:fenced\s+)?leanfm-canvas\s*\n\s*(<canvas\b[\s\S]*?<\/canvas>\s*<script\b[\s\S]*?<\/script>)/gi, (_block, source: string) => {
    canvases.push(source.trim());
    return "\n";
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

function QuestionForm({questions, answeredIds, disabled, onAnswer}: {questions: ChatQuestion[]; answeredIds: Set<string>; disabled?: boolean; onAnswer: (answer: string) => void}) {
  const unanswered = questions.filter(question => !answeredIds.has(question.id));
  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const [qualifications, setQualifications] = useState<Record<string, string>>({});
  const [validation, setValidation] = useState("");
  function choose(question: ChatQuestion, value: string, checked: boolean) {
    setSelected(current => ({...current, [question.id]: question.multiple ? (checked ? [...(current[question.id] || []), value] : (current[question.id] || []).filter(item => item !== value)) : [value]}));
  }
  function submitAnswers() {
    const incomplete = unanswered.find(question =>
      (selected[question.id] || []).length === 0 && (qualifications[question.id] || "").trim().length === 0);
    if (incomplete) {
      setValidation(`Answer “${incomplete.prompt}” by selecting a choice or entering qualifying text.`);
      return;
    }
    setValidation("");
    const answer = unanswered.map(question => {
      const values = selected[question.id] || [];
      const labels = values.map(value => question.options.find(option => option.value === value)?.label || value);
      const selectedAnswer = labels.length > 0 ? labels.map((label, index) => `${label} [${values[index]}]`).join(", ") : "No predefined option selected.";
      const qualification = (qualifications[question.id] || "").trim();
      return `Question ID: ${question.id}\n${question.prompt}\nAnswer: ${selectedAnswer}` + (qualification ? `\nQualification: ${qualification}` : "");
    }).join("\n\n");
    onAnswer(answer);
  }
  if (unanswered.length === 0) return <div className="answered-question-note">Already answered; this question is closed.</div>;
  return <section className="chat-questions" aria-label="Questions requiring answers">{unanswered.map(question => <fieldset key={question.id}><legend>{question.prompt}</legend>{question.options.map(option => <label key={option.value} className={(selected[question.id] || []).includes(option.value) ? "selected" : ""}><input type={question.multiple ? "checkbox" : "radio"} name={question.id} value={option.value} checked={(selected[question.id] || []).includes(option.value)} onChange={event => { setValidation(""); choose(question, option.value, event.target.checked); }} /> <span>{option.label}{option.recommended && <small>Recommended</small>}</span></label>)}<label className="question-qualification"><span>Qualify this decision or provide a better answer</span><textarea value={qualifications[question.id] || ""} onChange={event => { setValidation(""); setQualifications(current => ({...current, [question.id]: event.target.value})); }} maxLength={4000} rows={3} placeholder="Optional when a choice fits; use this alone when none does." /></label></fieldset>)}{validation && <p className="question-validation" role="alert">{validation}</p>}<button type="button" className="primary" disabled={disabled} onClick={submitAnswers}>Submit answers</button></section>;
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
  return <section className="auth"><div className="auth-card"><h1>LeanFM</h1><p>Sign in to unlock your encrypted OpenAI API key. This is not an OpenAI account login; the key is never stored in plaintext.</p>
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
      .catch((e: Error) => { reportClientError("Rendering a Mermaid diagram in the project workspace", e); if (current && ref.current) ref.current.textContent = `${e.message}\n\n${source}`; });
    return () => { current = false; };
  }, [source]);
  return <div ref={ref} className={className}><pre>{source}</pre></div>;
}

function MessageView({message, projectId, answeredIds, onDelete, onResend, onAnswer, disabled}: {message: Message; projectId: string; answeredIds: Set<string>; onDelete: () => void; onResend?: () => void; onAnswer?: (answer: string) => void; disabled?: boolean}) {
  const result = extractResult(message.text);
  const structured = extractQuestions(result.text);
  const canvasContent = extractCanvases(structured.text);
  const [answerText, activity] = canvasContent.text.split(/\n\nOperational trace:\n/, 2);
  const images = projectImagePaths(answerText, projectId);
  const videos = projectVideoPaths(answerText, projectId);
  const internetImages = remoteImages(answerText);
  const pieces = answerText.split(/```mermaid\s*\n?/i);
  const first = pieces.shift() || "";
  const sentAt = message.sent_at_ms === undefined ? undefined : new Date(message.sent_at_ms);
  const validSentAt = sentAt && !Number.isNaN(sentAt.getTime());
  const timestamp = validSentAt ? sentAt.toLocaleString([], {dateStyle: "medium", timeStyle: "medium"}) : "Time unavailable (legacy message)";
  return <article className={`message ${message.role}`}><time className="message-timestamp" dateTime={validSentAt ? sentAt.toISOString() : undefined} title={validSentAt ? sentAt.toISOString() : timestamp}>{timestamp}{message.model ? ` · ${message.model}` : ""}</time>{result.status && <div className={`result-badge ${result.status}`}>{result.status.toUpperCase()}</div>}<div className="message-text"><LatexText text={first} />{pieces.map((part, i) => {
    const end = part.indexOf("```");
    return end < 0 ? <LatexText key={i} text={`\`\`\`mermaid\n${part}`} /> : <React.Fragment key={i}><Mermaid source={part.slice(0, end).trim()} className="chat-diagram" /><LatexText text={part.slice(end + 3)} /></React.Fragment>;
  })}</div>{structured.invalid && <div className="request-error"><div className="result-badge fail">FAIL</div><p>The model returned a malformed question form. Resend this message to retry.</p></div>}{canvasContent.canvases.map((source, index) => <CanvasAnimation source={source} key={index} />)}{images.map(path => <ProjectImage projectId={projectId} path={path} key={path} />)}{videos.map(path => <figure className="chat-inline-figure" key={path}><video controls preload="metadata" src={`/api/projects/${projectId}/files/${path.split("/").map(encodeURIComponent).join("/")}`}><a href={`/api/projects/${projectId}/files/${path.split("/").map(encodeURIComponent).join("/")}`}>Open {path}</a></video><figcaption>{path}</figcaption></figure>)}{internetImages.map(image => <figure className="chat-inline-figure" key={image.url}><img src={image.url} alt={image.alt} loading="lazy" referrerPolicy="no-referrer" /><figcaption><a href={image.source} target="_blank" rel="noreferrer noopener">Source: {image.source}</a><CopyImageReference reference={`![${image.alt}](${image.url})\nSource: ${image.source}`} /></figcaption></figure>)}{activity && <details className="operational-trace"><summary>Operational trace</summary><pre>{activity}</pre></details>}{structured.questions.length > 0 && onAnswer && <QuestionForm questions={structured.questions} answeredIds={answeredIds} disabled={disabled} onAnswer={onAnswer} />}{message.response_time_ms !== undefined && <div className="response-time">Response time: {(message.response_time_ms / 1000).toFixed(1)} s</div>}{message.usage && <div className="usage">{message.usage.input_tokens} input · {message.usage.cached_input_tokens} cached · {message.usage.output_tokens} output · {message.usage.total_tokens} total · billed to your API key</div>}
    <div className="message-actions">{onResend && <button onClick={onResend} disabled={disabled}>Resend</button>}<button onClick={onDelete}>Delete</button></div></article>;
}

function Chat({project, models, defaultModel, onWorkspaceChange, onBusyChange}: {project: Project; models: string[]; defaultModel: string; onWorkspaceChange: () => void; onBusyChange: (busy: boolean, model?: string) => void}) {
  const [messages, setMessages] = useState<Message[]>([]), [prompt, setPrompt] = useState(""), [queue, setQueue] = useState<QueuedPrompt[]>([]), [busy, setBusy] = useState(false), [error, setError] = useState(""), [errorAction, setErrorAction] = useState(""), [errorTrace, setErrorTrace] = useState("");
  const [model, setModel] = useState(defaultModel);
  const conversationEndRef = useRef<HTMLDivElement>(null);
  const answeredIds = new Set(messages.flatMap(message => [...message.text.matchAll(/Question ID:\s*([A-Za-z0-9._-]+)/g)].map(match => match[1])));
  const pendingQuestion = latestUnansweredQuestion(messages, answeredIds);
  useEffect(() => {
    window.requestAnimationFrame(() => conversationEndRef.current?.scrollIntoView({block: "end"}));
  }, [messages.length, error]);
  async function load(signal?: AbortSignal) { const data = await api<{messages: Message[]}>(`/api/projects/${project.project_id}/conversation`, {}, signal); setMessages(data.messages || []); }
  useEffect(() => { const controller = new AbortController(); if (!project.read_only) load(controller.signal).catch(e => { if (e.name !== "AbortError") setError(e.message); }); return () => controller.abort(); }, [project.project_id]);
  useEffect(() => { if (!models.includes(model)) setModel(defaultModel || models[0] || ""); }, [models, defaultModel, model]);
  function enqueue(text: string, clearComposer = false, pendingQuestion?: QueuedPrompt["pendingQuestion"]) {
    text = text.trim();
    if (!text) return;
    const id = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    if (!model) return;
    setQueue(current => [...current, {id, text, model, pendingQuestion}]);
    if (clearComposer) setPrompt("");
  }
  async function run(item: QueuedPrompt) {
    setMessages(v => [...v, {message_id: `pending-${item.id}`, role: "user", text: item.text, sent_at_ms: Date.now()}]); setBusy(true); onBusyChange(true, item.model); setError(""); setErrorAction(""); setErrorTrace("");
    try { await api(`/api/projects/${project.project_id}/chat`, formRequest({prompt: item.text, model: item.model, ...(item.pendingQuestion ? {composer_question_id: item.pendingQuestion.id, composer_question_prompt_length: String(item.pendingQuestion.promptLength), composer_text_length: String(item.pendingQuestion.composerTextLength)} : {})})); await load(); onWorkspaceChange(); } catch (e) { setMessages(v => v.filter(message => message.message_id !== `pending-${item.id}`)); setError((e as Error).message); if (e instanceof ApiError) { setErrorAction(e.action); setErrorTrace("LeanFM error report (safe to paste to Codex)\n" + JSON.stringify({...e.trace, project_id: project.project_id, model: item.model}, null, 2)); } else setErrorAction("Retry once. If it fails again, report this message to Codex."); await load().catch(() => {}); onWorkspaceChange(); } finally { setBusy(false); onBusyChange(false); } }
  useEffect(() => {
    if (busy || queue.length === 0) return;
    const [next, ...remaining] = queue;
    setQueue(remaining);
    void run(next);
  }, [busy, queue]);
  function send(event: FormEvent) {
    event.preventDefault();
    const text = prompt.trim();
    if (!text) return;
    const answer = pendingQuestion
      ? `Question ID: ${pendingQuestion.id}\n${pendingQuestion.prompt}\nAnswer: No predefined option selected.\nQualification: ${text}`
      : text;
    enqueue(answer, true, pendingQuestion ? {id: pendingQuestion.id, promptLength: pendingQuestion.prompt.length, composerTextLength: text.length} : undefined);
  }
  async function remove(id: string) { if (!confirm("Delete this message from the project conversation?")) return; await api(`/api/projects/${project.project_id}/conversation/messages/${encodeURIComponent(id)}`, {method: "DELETE"}); await load(); }
  if (project.read_only) return <div className="empty"><div><h2>Read-only workspace</h2><p>Select an editable project to chat.</p></div></div>;
  return <section className="pane chat-pane">
    <div className="messages">{messages.length ? messages.map(m => <MessageView key={m.message_id} message={m} projectId={project.project_id} answeredIds={answeredIds} onDelete={() => remove(m.message_id)} onResend={m.role === "user" ? () => enqueue(m.text) : undefined} onAnswer={m.role === "assistant" ? enqueue : undefined} disabled={false} />) : <div className="empty"><div><h2>What are we building?</h2><p>Start informally. LeanFM will grow the book and specifications with you.</p></div></div>}{error && <div className="request-error"><div className="result-badge fail">FAIL</div><p className="error">{error}</p><p className="error-action"><strong>What to do:</strong> {errorAction}</p>{errorTrace && <details open><summary>Diagnostic for Codex</summary><button onClick={() => navigator.clipboard.writeText(errorTrace)}>Copy diagnostic</button><pre>{errorTrace}</pre></details>}</div>}<div ref={conversationEndRef} aria-hidden="true" /></div>
    <div className="composer-wrap">{pendingQuestion && <p className="pending-question-hint">Your next message will answer: “{pendingQuestion.prompt}”</p>}{queue.length > 0 && <div className="prompt-queue" aria-label="Queued prompts"><strong>{queue.length} queued</strong>{queue.map((item, index) => <div key={item.id}><span>{index + 1}. [{item.model}] {item.text}</span><button onClick={() => setQueue(current => current.filter(queued => queued.id !== item.id))} aria-label={`Remove queued prompt ${index + 1}`}>Remove</button></div>)}</div>}<form className="composer" onSubmit={send}><textarea value={prompt} onChange={e => setPrompt(e.target.value)} placeholder={busy ? "Stack another prompt…" : "What are you trying to build?"} /><button disabled={!prompt.trim() || !model}>Send</button><label className="model-picker">Model<select value={model} onChange={event => setModel(event.target.value)} aria-label="Model for new prompts">{models.map(option => <option key={option} value={option}>{option}</option>)}</select></label></form></div></section>;
}

function Book({project, workspaceRevision}: {project: Project; workspaceRevision: number}) {
  const [source, setSource] = useState(""), [status, setStatus] = useState("Loading book…"), [revision, setRevision] = useState(0), [dark, setDark] = useState(true);
  const [sourceRevision, setSourceRevision] = useState("");
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
  useEffect(() => { const controller = new AbortController(); api<{source: string; source_revision: string}>(`/api/projects/${project.project_id}/book`, {}, controller.signal).then(d => { setSource(d.source); setSourceRevision(d.source_revision); setStatus(project.read_only ? "Read-only book" : "book/main.tex · saved"); setRevision(Date.now()); }).catch(e => { if (e.name !== "AbortError") setStatus(e.message); }); return () => controller.abort(); }, [project.project_id, workspaceRevision]);
  async function save() { setStatus("Saving…"); const saved = await api<{source_revision: string}>(`/api/projects/${project.project_id}/book`, formRequest({source, source_revision: sourceRevision})); setSourceRevision(saved.source_revision); setStatus("Saved; PDF build required"); }
  async function build() { setStatus("Building PDFs…"); const saved = await api<{source_revision: string}>(`/api/projects/${project.project_id}/book`, formRequest({source, source_revision: sourceRevision})); setSourceRevision(saved.source_revision); await api(`/api/projects/${project.project_id}/book/build`, {method: "POST"}); setStatus("Book built successfully"); setRevision(Date.now()); }
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
  return <section className="pane diagrams-pane"><header className="diagrams-header"><h1>Tasks</h1><div className="diagram-kind">{[["interaction","Productions · interaction"],["state","States · state machine"],["properties","Properties · CTL"],["constraints","where_ · CTL guards"]].map(([id,label]) => <button key={id} className={kind === id ? "active" : ""} onClick={() => setKind(id)}>{label}</button>)}</div></header><div className="diagrams-workbench"><nav className="diagram-task-list vertical-tabs">{tasks.map(t => <button key={t.id} className={`diagram-task ${selected === t.id ? "active" : ""}`} onClick={() => setSelected(t.id)}><strong>{t.title}</strong><span>{t.transitions.length} productions · {t.states.length} states</span></button>)}</nav><main className="diagram-stage"><h2>{task?.title}</h2>{task && (kind === "interaction" || kind === "state") && <Mermaid source={kind === "interaction" ? task.interaction_mermaid : task.state_mermaid} />}{task && kind === "properties" && task.properties.map(p => <article className="task-clause" key={p.name}><strong>{p.name}</strong><pre>{p.formula}</pre><small>{p.origin} · declared mode: {p.mode}</small></article>)}{task && kind === "constraints" && task.constraints.map(c => <article className="task-clause" key={c.id}><strong>where_ {c.id}</strong><pre>{c.formula}</pre><small>{c.origin}</small></article>)}</main></div></section>;
}

function Source({project, workspaceRevision, agentBusy}: {project: Project; workspaceRevision: number; agentBusy: boolean}) {
  const [files, setFiles] = useState<string[]>([]), [selected, setSelected] = useState(""), [source, setSource] = useState(""), [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    const refresh = () => api<{files: string[]}>(`/api/projects/${project.project_id}/source`, {}, controller.signal).then(result => {
      const next = result.files || [];
      setFiles(next); setSelected(current => current && next.includes(current) ? current : (next[0] || "")); setError("");
    }).catch(e => { if (e.name !== "AbortError") setFiles(current => { if (!current.length) setError(e.message); return current; }); });
    void refresh();
    const timer = agentBusy ? window.setInterval(refresh, 2000) : undefined;
    return () => { controller.abort(); if (timer !== undefined) window.clearInterval(timer); };
  }, [project.project_id, workspaceRevision, agentBusy]);
  useEffect(() => {
    if (!selected) return;
    const controller = new AbortController();
    const path = selected.split("/").map(encodeURIComponent).join("/");
    api<{source: string}>(`/api/projects/${project.project_id}/source/${path}`, {}, controller.signal).then(result => { setSource(result.source); setError(""); }).catch(e => { if (e.name !== "AbortError") { setSource(""); setError(e.message); } });
    return () => controller.abort();
  }, [project.project_id, selected]);
  if (error && !files.length) return <div className="empty"><p className="error">{error}</p></div>;
  if (!files.length) return <div className="empty"><div><h1>Source</h1><p>No implementation source exists yet. Ask for implementation after accepting both the requirements and implementation specification; LeanFM will ask focused blocking questions if those inputs are incomplete.</p></div></div>;
  return <section className="pane source-pane"><nav className="source-files vertical-tabs">{files.map(file => <button key={file} className={selected === file ? "active" : ""} onClick={() => setSelected(file)}>{file}</button>)}</nav><main className="source-view"><header><strong>{selected}</strong></header>{error ? <p className="error">{error}</p> : <pre><code>{source}</code></pre>}</main></section>;
}

function ProjectMemoryView({project, workspaceRevision, agentBusy}: {project: Project; workspaceRevision: number; agentBusy: boolean}) {
  const [memory, setMemory] = useState<ProjectMemory | null>(null), [selected, setSelected] = useState("book"), [source, setSource] = useState(""), [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    const refresh = () => api<ProjectMemory>(`/api/projects/${project.project_id}/memory`, {}, controller.signal).then(result => { setMemory(result); setError(""); }).catch(e => { if (e.name !== "AbortError") setMemory(current => { if (!current) setError(e.message); return current; }); });
    void refresh();
    const timer = agentBusy ? window.setInterval(refresh, 2000) : undefined;
    return () => { controller.abort(); if (timer !== undefined) window.clearInterval(timer); };
  }, [project.project_id, workspaceRevision, agentBusy]);
  useEffect(() => {
    if (selected === "source-summary") { setSource(""); setError(""); return; }
    const controller = new AbortController();
    api<{source: string}>(`/api/projects/${project.project_id}/memory/${selected}`, {}, controller.signal).then(result => { setSource(result.source); setError(""); }).catch(e => { if (e.name !== "AbortError") { setSource(""); setError(e.message); } });
    return () => controller.abort();
  }, [project.project_id, selected, workspaceRevision]);
  const complete = (memory?.files.filter(file => file.status === "current").length || 0) + ((memory?.source_files || 0) > 0 ? 1 : 0);
  return <section className="pane memory-pane"><header className="memory-header"><div><h1>Project memory</h1><p>Durable state used to resume without conversation history.</p></div><strong>{complete} / 5 substantive layers</strong></header><div className="memory-workbench"><nav className="memory-files vertical-tabs">{memory?.files.map(file => <button key={file.id} className={selected === file.id ? "active" : ""} onClick={() => setSelected(file.id)}><span><strong>{file.label}</strong><small>{file.path}</small></span><em className={`memory-status ${file.status}`}>{file.status}</em></button>)}<button className="memory-source-summary" onClick={() => setSelected("source-summary")}><span><strong>Implementation source</strong><small>source/ · {memory?.source_files || 0} files · {memory?.source_bytes || 0} bytes</small></span><em className={`memory-status ${(memory?.source_files || 0) > 0 ? "current" : "missing"}`}>{(memory?.source_files || 0) > 0 ? "current" : "missing"}</em></button></nav><main className="source-view"><header><strong>{selected === "source-summary" ? "source/" : memory?.files.find(file => file.id === selected)?.path}</strong><span>Refreshes after every chat turn</span></header>{error ? <p className="error">{error}</p> : selected === "source-summary" ? <div className="memory-source-help"><h2>{memory?.source_files || 0} implementation files</h2><p>Open the Source phase to inspect generated implementation files. Source appears only after both acceptance gates and the security critique.</p></div> : <pre><code>{source}</code></pre>}</main></div></section>;
}

function ProjectWorkspace({project}: {project: Project}) {
  const [phase, setPhase] = useState<Phase>("chat");
  const [billing, setBilling] = useState<Billing | null>(null);
  const [workspaceRevision, setWorkspaceRevision] = useState(0);
  const [agentBusy, setAgentBusy] = useState(false);
  const [agentModel, setAgentModel] = useState(""), [agentSeconds, setAgentSeconds] = useState(0), [cancelRequested, setCancelRequested] = useState(false);
  const [agentStatus, setAgentStatus] = useState<{stage: string; detail: string; attempt: number} | null>(null);
  const [liveTrace, setLiveTrace] = useState<string[]>([]);
  useEffect(() => {
    if (!agentBusy) { setAgentSeconds(0); return; }
    const started = Date.now();
    const timer = window.setInterval(() => setAgentSeconds(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => window.clearInterval(timer);
  }, [agentBusy]);
  useEffect(() => {
    if (!agentBusy) return;
    let current = true;
    const refresh = () => {
      api<{stage: string; detail: string; attempt: number}>(`/api/projects/${project.project_id}/chat/status`)
        .then(status => { if (current) setAgentStatus(status); }).catch(() => {});
      api<{entries: string[]}>(`/api/projects/${project.project_id}/chat/trace`)
        .then(trace => { if (current) setLiveTrace(trace.entries || []); }).catch(() => {});
    };
    void refresh();
    const timer = window.setInterval(refresh, 2000);
    return () => { current = false; window.clearInterval(timer); };
  }, [project.project_id, agentBusy]);
  useEffect(() => {
    let current = true;
    const refresh = () => api<{billing: Billing | null}>("/api/me").then(result => { if (current) setBilling(result.billing); }).catch(() => {});
    void refresh();
    const timer = window.setInterval(refresh, 3000);
    return () => { current = false; window.clearInterval(timer); };
  }, []);
  const percentRemaining = billing?.token_budget ? Math.round(100 * billing.tokens_remaining / billing.token_budget) : 0;
  const agentElapsed = `${String(Math.floor(agentSeconds / 60)).padStart(2, "0")}:${String(agentSeconds % 60).padStart(2, "0")}`;
  const agentProgress = cancelRequested ? "Cancellation requested; waiting for the current safe boundary" : agentStatus?.detail || (agentSeconds >= 120 ? "Long-running model or tool work is still active" : agentSeconds >= 30 ? "Model or workspace tools are still working" : "Contacting the model");
  function agentState(busy: boolean, model?: string) { setAgentBusy(busy); if (busy) { setAgentModel(model || ""); setCancelRequested(false); setAgentStatus(null); setLiveTrace([]); } }
  async function cancelAgent() { setCancelRequested(true); try { await api(`/api/projects/${project.project_id}/chat/cancel`, {method: "POST"}); } catch { setCancelRequested(false); } }
  return <main className="main"><header className="topbar"><strong>{project.display_name}</strong><nav className="phase-tabs"><div className="phase-group"><span>Durable</span><button className={phase === "memory" ? "tab active" : "tab"} onClick={() => setPhase("memory")}>Project memory</button></div><div className="phase-group"><span>Discover</span><div><button className={phase === "chat" ? "tab active" : "tab"} onClick={() => setPhase("chat")}>Chat</button><button className={phase === "book" ? "tab active" : "tab"} onClick={() => setPhase("book")}>Book</button></div></div><div className="phase-group"><span>Specify</span><div><button className={phase === "grammar" ? "tab active" : "tab"} onClick={() => setPhase("grammar")}>Grammar</button><button className={phase === "tasks" ? "tab active" : "tab"} onClick={() => setPhase("tasks")}>Tasks</button></div></div><div className="phase-group"><span>Build</span><button className={phase === "source" ? "tab active" : "tab"} onClick={() => setPhase("source")}>Source</button></div></nav>{billing && <div className={`billing-meter ${percentRemaining <= 10 ? "danger" : percentRemaining <= 25 ? "warn" : ""}`} title="This is a local token safety budget, not an OpenAI dollar balance. The provider project spend limit is authoritative."><strong>{billing.provider} · key {billing.key_fingerprint}</strong><span>default · {billing.model}</span><span>{billing.tokens_used.toLocaleString()} used · {billing.tokens_remaining.toLocaleString()} remaining</span><small>Local session limit; enforce a provider project spend cap</small></div>}</header>
    {agentBusy && <div className="workspace-agent-progress"><div className="workspace-agent-running" role="status"><span className="agent-running-dot" /><span><strong>Agent running · {agentModel}</strong><small>{agentProgress}. You can inspect any project or phase while it runs.</small></span><time>{agentElapsed}</time><button type="button" onClick={cancelAgent} disabled={cancelRequested}>{cancelRequested ? "Cancel requested…" : "Cancel"}</button></div>{liveTrace.length > 0 && <details className={`live-operational-trace ${liveTrace.some(entry => entry.includes("rejected:") || entry.startsWith("Failed check:")) ? "has-error" : ""}`}><summary>Operational trace · {liveTrace.length} event{liveTrace.length === 1 ? "" : "s"} · latest: {liveTrace[liveTrace.length - 1]}</summary><pre>{liveTrace.map(entry => `- ${entry}`).join("\n")}</pre></details>}</div>}
    <div className="phase-panel" hidden={phase !== "chat"}><Chat project={project} models={billing?.models || []} defaultModel={billing?.model || ""} onWorkspaceChange={() => setWorkspaceRevision(value => value + 1)} onBusyChange={agentState} /></div>
    <div className="phase-panel" hidden={phase !== "memory"}><ProjectMemoryView project={project} workspaceRevision={workspaceRevision} agentBusy={agentBusy} /></div>
    <div className="phase-panel" hidden={phase !== "book"}><Book project={project} workspaceRevision={workspaceRevision} /></div>
    <div className="phase-panel" hidden={phase !== "grammar"}><Specification project={project} view="grammar" /></div>
    <div className="phase-panel" hidden={phase !== "tasks"}><Specification project={project} view="tasks" /></div>
    <div className="phase-panel" hidden={phase !== "source"}><Source project={project} workspaceRevision={workspaceRevision} agentBusy={agentBusy} /></div>
  </main>;
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
  useEffect(() => { setClientDiagnosticProject(selected); }, [selected]);
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
  return <div className="app"><aside className="sidebar"><div className="brand">LeanFM</div><form onSubmit={create}><input value={newName} onChange={e => setNewName(e.target.value)} placeholder="New project name" required /><button className="new-project">＋ Add project</button></form><div className="tab-set-label">Projects</div><div className="projects vertical-tabs">{projects.map(item => <div className="project-row" key={item.project_id}><button className={`project ${selected === item.project_id ? "active" : ""}`} onClick={() => setSelected(item.project_id)}>{item.display_name}{item.read_only && <span className="project-kind">read-only</span>}</button>{!item.read_only && <button className="project-delete" onClick={() => remove(item)}>Delete</button>}</div>)}</div><div className="sidebar-footer"><div className="font-controls" aria-label="Font zoom"><button type="button" aria-label="Decrease font size" disabled={fontScale <= .8} onClick={() => setFontScale(value => Math.max(.8, Number((value - .1).toFixed(1))))}>−</button><output aria-live="polite">{Math.round(fontScale * 100)}%</output><button type="button" aria-label="Increase font size" onClick={() => setFontScale(value => Number((value + .1).toFixed(1)))}>＋</button></div><span>{user}</span></div></aside>{projects.map(item => <div className="project-panel" hidden={selected !== item.project_id} key={`${user}:${item.project_id}`}><ProjectWorkspace project={item} /></div>)}{!project && <main className="main"><div className="empty"><h2>Create or select a project</h2></div></main>}</div>;
}

createRoot(document.getElementById("root")!).render(<ClientFaultBarrier><App /></ClientFaultBarrier>);
